// tools/minting/smoke_wager.ts
// M-P4 end-to-end proof against prod (sim): one-active-card swap flow through the
// deployed cinematic-mint + wager escrow/transfer/return via mig 142. Uses two
// dedicated smoke users (dev tooling — removed at the pre-launch reset, ARCHIVE §A8).
//
// SUPABASE_URL=… SUPABASE_SERVICE_ROLE_KEY=… SUPABASE_ANON_KEY=… \
//   [SMOKE_USER_ID=…] [SMOKE_USER2_ID=…] \
//   deno run --allow-net --allow-env tools/minting/smoke_wager.ts

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const URL_ = Deno.env.get('SUPABASE_URL')!;
const SR = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const ANON = Deno.env.get('SUPABASE_ANON_KEY')!;
const PASS = 'smoke-' + SR.slice(-12);

const admin = createClient(URL_, SR);
const fail = (m: string): never => { console.error(`SMOKE FAIL: ${m}`); Deno.exit(1); };

async function smokeUser(email: string, fallbackEnv: string): Promise<string> {
  const created = await admin.auth.admin.createUser({ email, password: PASS, email_confirm: true });
  if (created.data.user) return created.data.user.id;
  const { data } = await admin.auth.admin.listUsers();
  const id = data?.users?.find((u) => u.email === email)?.id ?? Deno.env.get(fallbackEnv) ??
    fail(`cannot create/find ${email} (set ${fallbackEnv})`);
  const upd = await admin.auth.admin.updateUserById(id, { password: PASS });
  if (upd.error) fail(`password reset ${email}: ${upd.error.message}`);
  return id;
}

async function clearSlot(userId: string) {
  for (let i = 0; i < 5; i++) {
    const { data: slot } = await admin.rpc('self_mint_slot', { p_user: userId });
    if (!slot) return;
    const { data: held } = await admin.from('chit_ownership')
      .select('quantity').eq('user_id', userId).eq('chit_id', slot).single();
    if ((held?.quantity ?? 0) > 0) {
      await admin.rpc('chit_grant', {
        p_user_id: userId, p_chit_id: slot, p_quantity: -held!.quantity,
        p_reason: 'platform_correction',
      });
    }
    await admin.from('moment_chits')
      .update({ is_active: false, retired_at: new Date().toISOString(), retired_reason: 'admin' })
      .eq('id', slot);
  }
}

const qty = async (userId: string, chitId: string): Promise<number> => {
  const { data } = await admin.from('chit_ownership')
    .select('quantity').eq('user_id', userId).eq('chit_id', chitId).maybeSingle();
  return data?.quantity ?? 0;
};

const u1 = await smokeUser('cinematic-smoke@noraplatforms.com', 'SMOKE_USER_ID');
const u2 = await smokeUser('cinematic-smoke-2@noraplatforms.com', 'SMOKE_USER2_ID');
await clearSlot(u1); await clearSlot(u2);
const retireLater: string[] = [];
const momentsLater: string[] = [];
const matchesLater: string[] = [];

// ═══ Part 1: wager match — escrow → finish → transfer (attribution intact) ═══════
{
  const mk = async (name: string, family: string) => {
    const { data, error } = await admin.rpc('create_moment_chit', {
      p_name: name, p_family: family, p_chit_type: 'creature', p_tier: 'C',
    });
    if (error || !data) fail(`create_moment_chit: ${error?.message}`);
    retireLater.push(data);
    return data as string;
  };
  const c1 = await mk('M-P4 wager smoke stake 1', 'athlete');
  const c2 = await mk('M-P4 wager smoke stake 2', 'musician');
  await admin.from('moment_chits').update({ original_minter_handle: '@smoke_minter_2' }).eq('id', c2);
  for (const [u, c] of [[u1, c1], [u2, c2]] as const) {
    const { error } = await admin.rpc('chit_grant', { p_user_id: u, p_chit_id: c, p_quantity: 1, p_reason: 'event' });
    if (error) fail(`chit_grant: ${error.message}`);
  }

  const { data: match, error: wErr } = await admin.rpc('ccg_create_wager_match', {
    p_seat1_user: u1, p_seat1_deck: null, p_seat1_stake: c1,
    p_seat2_user: u2, p_seat2_deck: null, p_seat2_stake: c2,
    p_is_test: true,
  });
  if (wErr || !match) fail(`ccg_create_wager_match: ${wErr?.message}`);
  matchesLater.push(match);
  if (await qty(u1, c1) !== 0 || await qty(u2, c2) !== 0) fail('escrow must drain both holdings');

  // double-stake blocked
  const dbl = await admin.rpc('ccg_create_wager_match', {
    p_seat1_user: u1, p_seat1_deck: null, p_seat1_stake: c1,
    p_seat2_user: u2, p_seat2_deck: null, p_seat2_stake: c2,
    p_is_test: true,
  });
  if (!dbl.error) fail('double-stake of an escrowed chit must be blocked');

  // seat 1 wins → transfer + return, attribution survives, idempotent
  const { error: finErr } = await admin.from('ccg_matches')
    .update({ status: 'finished', winner_seat: 1, finished_at: new Date().toISOString() })
    .eq('id', match);
  if (finErr) fail(`finish match: ${finErr.message}`);
  if (await qty(u1, c2) !== 1) fail('winner must receive the loser stake');
  if (await qty(u1, c1) !== 1) fail('winner stake must return');
  if (await qty(u2, c2) !== 0) fail('loser copy must be gone');
  const { data: chit2 } = await admin.from('moment_chits')
    .select('original_minter_handle').eq('id', c2).single();
  if (chit2?.original_minter_handle !== '@smoke_minter_2') fail('attribution must survive transfer');
  await admin.rpc('ccg_settle_wager', { p_match_id: match });
  if (await qty(u1, c2) !== 1) fail('settle must be idempotent');
  const { data: esc } = await admin.from('ccg_wager_escrow').select('seat,status').eq('match_id', match);
  const statuses = Object.fromEntries((esc ?? []).map((r) => [r.seat, r.status]));
  if (statuses[1] !== 'returned' || statuses[2] !== 'transferred') fail(`escrow statuses wrong: ${JSON.stringify(esc)}`);
  console.log(`wager transfer OK (match=${match}: winner keeps stake + takes loser chit, attribution intact)`);

  // abandoned match returns both stakes (stake the two chits u1 now holds vs a fresh one for u2)
  const c3 = await mk('M-P4 wager smoke stake 3', 'gamer');
  await admin.rpc('chit_grant', { p_user_id: u2, p_chit_id: c3, p_quantity: 1, p_reason: 'event' });
  const { data: match2, error: w2Err } = await admin.rpc('ccg_create_wager_match', {
    p_seat1_user: u1, p_seat1_deck: null, p_seat1_stake: c1,
    p_seat2_user: u2, p_seat2_deck: null, p_seat2_stake: c3,
    p_is_test: true,
  });
  if (w2Err || !match2) fail(`second wager match: ${w2Err?.message}`);
  matchesLater.push(match2);
  await admin.from('ccg_matches').update({ status: 'abandoned' }).eq('id', match2);
  if (await qty(u1, c1) !== 1 || await qty(u2, c3) !== 1) fail('abandoned match must return both stakes');
  console.log('wager abandon OK (both stakes returned)');
}

// ═══ Part 2: one-active-card swap through the deployed cinematic-mint ═══════════
{
  const userClient = createClient(URL_, ANON);
  const { data: session, error: sErr } = await userClient.auth.signInWithPassword({
    email: 'cinematic-smoke@noraplatforms.com', password: PASS,
  });
  if (sErr || !session.session) fail(`sign-in: ${sErr?.message}`);
  const mintCall = (body: Record<string, unknown>) =>
    fetch(`${URL_}/functions/v1/cinematic-mint`, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${session.session!.access_token}`,
        apikey: ANON, 'Content-Type': 'application/json',
      },
      body: JSON.stringify(body),
    });
  const makeMoment = async (tag: string) => {
    const { data: momentId, error } = await admin.rpc('moment_record', {
      p_owner: u1, p_platform: 'youtube', p_external_id: `mp4-swap-${tag}-${crypto.randomUUID()}`,
      p_url: 'https://www.youtube.com/watch?v=swapsmoke', p_thumbnail: null,
      p_engagement: 60000, p_consent: true, p_handle: '@smoke_creator',
    });
    if (error) fail(`moment_record: ${error.message}`);
    momentsLater.push(momentId);
    await admin.rpc('moment_pre_gen_moderate', {
      p_moment_id: momentId, p_verdict: 'approved', p_labels: null, p_third_party: false, p_model: 'sim',
    });
    return momentId as string;
  };

  // first self-mint fills the slot
  const momentA = await makeMoment('a');
  const resA = await mintCall({
    moment_id: momentA, family: 'athlete', chit_type: 'creature', timing_type: 'on_summon',
    name: 'Swap Smoke A', subject_desc: 'a cel-shaded sprinter exploding off the blocks',
  });
  const mintA = await resA.json();
  if (!resA.ok || !mintA.chit_id) fail(`mint A: HTTP ${resA.status} ${JSON.stringify(mintA)}`);
  retireLater.push(mintA.chit_id);

  // second self-mint without confirmation → 409 with the warning contract
  const momentB = await makeMoment('b');
  const resBlocked = await mintCall({
    moment_id: momentB, family: 'gamer', chit_type: 'creature', timing_type: 'on_summon',
    name: 'Swap Smoke B', subject_desc: 'a cel-shaded gamer landing a clutch play',
  });
  const blocked = await resBlocked.json();
  if (resBlocked.status !== 409 || blocked.error !== 'self_mint_slot_occupied') {
    fail(`expected 409 self_mint_slot_occupied, got ${resBlocked.status}: ${JSON.stringify(blocked)}`);
  }
  if (blocked.occupied_chit_id !== mintA.chit_id) fail('409 must name the occupying chit');
  console.log('slot gate OK (second self-mint blocked with swap warning)');

  // confirmed swap → new chit lands, old chit retired + media removed
  const resSwap = await mintCall({
    moment_id: momentB, family: 'gamer', chit_type: 'creature', timing_type: 'on_summon',
    name: 'Swap Smoke B', subject_desc: 'a cel-shaded gamer landing a clutch play',
    swap_of_chit_id: mintA.chit_id, swap_confirm: true,
  });
  const swap = await resSwap.json();
  if (!resSwap.ok || !swap.chit_id) fail(`swap mint: HTTP ${resSwap.status} ${JSON.stringify(swap)}`);
  retireLater.push(swap.chit_id);
  if (swap.swapped_out_chit_id !== mintA.chit_id) fail('swap response must name the retired chit');
  const { data: oldChit } = await admin.from('moment_chits')
    .select('is_active,retired_reason').eq('id', mintA.chit_id).single();
  if (oldChit?.is_active !== false || oldChit?.retired_reason !== 'swap') fail('old chit must be retired (swap)');
  if (await qty(u1, mintA.chit_id) !== 0) fail('old chit holdings must be zero');
  if (await qty(u1, swap.chit_id) !== 1) fail('new chit must be held');
  const { data: leftovers } = await admin.storage.from('battle-media').list(`moments/${momentA}`, { limit: 10 });
  if ((leftovers ?? []).some((e) => e.id)) fail('old chit media must be deleted from battle-media');
  const { data: slotNow } = await admin.rpc('self_mint_slot', { p_user: u1 });
  if (slotNow !== swap.chit_id) fail('slot must now hold the new chit');
  console.log(`swap OK (old ${mintA.chit_id} retired + media gone; new ${swap.chit_id} holds the slot; media_deleted=${swap.swapped_media_deleted})`);
}

// ═══ cleanup (ledger is append-only: zero holdings, retire chits, drop rows) ═════
await clearSlot(u1);
for (const c of retireLater) {
  for (const u of [u1, u2]) {
    const q = await qty(u, c);
    if (q > 0) {
      await admin.rpc('chit_grant', { p_user_id: u, p_chit_id: c, p_quantity: -q, p_reason: 'platform_correction' });
    }
  }
  await admin.from('moment_chits')
    .update({ is_active: false, retired_at: new Date().toISOString(), retired_reason: 'admin' })
    .eq('id', c).is('retired_at', null);
}
for (const m of matchesLater) await admin.from('ccg_matches').delete().eq('id', m);
for (const m of momentsLater) await admin.from('moments').delete().eq('id', m);
console.log('M-P4 SMOKE PASSED: wager escrow/transfer/abandon + one-active-card swap all enforced');
