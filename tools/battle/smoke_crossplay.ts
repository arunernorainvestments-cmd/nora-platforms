// tools/battle/smoke_crossplay.ts — live E2E proof of the crossplay matchmaking
// rail (migration 159 + NORA_PLATFORMS_CROSSPLAY_SPEC.md).
//
// Creates two throwaway smoke users, gives each a legal 20-card deck of catalog
// chits, runs the full loop against PROD:
//   A joins queue → B joins → PAIRED into one ccg_match (A seat 1, B seat 2)
//   → A plays a real turn via ccg_submit_turn → RLS probe (B cannot read A's hand)
//   → B forfeits → match finished, winner seat 1 → full cleanup (match, decks,
//   holdings zeroed via compensating ledger rows, chits retired, users deleted).
//
// Run:  SUPABASE_URL=https://<ref>.supabase.co \
//       SERVICE_KEY=... ANON_KEY=... \
//       deno run --allow-net --allow-env tools/battle/smoke_crossplay.ts

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const url = Deno.env.get('SUPABASE_URL')!;
const serviceKey = Deno.env.get('SERVICE_KEY')!;
const anonKey = Deno.env.get('ANON_KEY')!;
if (!url || !serviceKey || !anonKey) throw new Error('SUPABASE_URL/SERVICE_KEY/ANON_KEY required');

const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
const PASS = 'smoke-' + crypto.randomUUID();
const EMAILS = ['crossplay-smoke-1@noraplatforms.com', 'crossplay-smoke-2@noraplatforms.com'];

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(`SMOKE FAIL: ${msg}`);
}

async function ensureUser(email: string): Promise<string> {
  const { data, error } = await admin.auth.admin.createUser({
    email, password: PASS, email_confirm: true,
  });
  if (data?.user) return data.user.id;
  // Already exists (leftover from an aborted run). GoTrue admin listUsers 500s
  // on this project, so recover the id via a read-only management-API query,
  // then reset the password to this run's PASS.
  if (error && /already been registered/i.test(error.message)) {
    const mgmtToken = Deno.env.get('MGMT_TOKEN');
    const ref = new URL(url).hostname.split('.')[0];
    if (!mgmtToken) throw new Error(`user ${email} exists; set MGMT_TOKEN to recover`);
    const res = await fetch(`https://api.supabase.com/v1/projects/${ref}/database/query`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${mgmtToken}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ query: `SELECT id FROM auth.users WHERE email = '${email}'` }),
    });
    const rows = await res.json() as { id: string }[];
    const id = rows?.[0]?.id;
    if (!id) throw new Error(`could not recover id for ${email}`);
    const { error: upErr } = await admin.auth.admin.updateUserById(id, { password: PASS });
    if (upErr) throw new Error(`password reset for ${email}: ${upErr.message}`);
    return id;
  }
  throw new Error(`createUser failed for ${email}: ${error?.message}`);
}

async function main() {
  console.log('1. users…');
  const uA = await ensureUser(EMAILS[0]);
  const uB = await ensureUser(EMAILS[1]);

  console.log('2. catalog chits + holdings (10 distinct × 2 copies each)…');
  const chitIds: string[] = [];
  for (let i = 0; i < 10; i++) {
    const { data, error } = await admin.rpc('create_moment_chit', {
      p_name: `Crossplay Smoke ${i + 1}`,
      p_family: 'athlete',
      p_chit_type: 'creature',
      p_tier: 'F',
    });
    if (error) throw new Error(`create_moment_chit: ${error.message}`);
    chitIds.push(data as string);
  }
  for (const u of [uA, uB]) {
    for (const c of chitIds) {
      const { error } = await admin.rpc('chit_grant', {
        p_user_id: u, p_chit_id: c, p_quantity: 2, p_reason: 'event',
      });
      if (error) throw new Error(`chit_grant: ${error.message}`);
    }
  }

  console.log('3. sign in both users…');
  const cA = createClient(url, anonKey, { auth: { persistSession: false } });
  const cB = createClient(url, anonKey, { auth: { persistSession: false } });
  for (const [c, email] of [[cA, EMAILS[0]], [cB, EMAILS[1]]] as const) {
    const { error } = await c.auth.signInWithPassword({ email, password: PASS });
    if (error) throw new Error(`sign-in ${email}: ${error.message}`);
  }

  console.log('4. decks (client-side, RLS + deck_set_chits)…');
  const decks: string[] = [];
  for (const c of [cA, cB]) {
    const uid = (await c.auth.getUser()).data.user!.id;
    let { data: deck } = await c.from('decks').select('id')
      .eq('user_id', uid).eq('name', 'Crossplay Smoke Deck').maybeSingle();
    if (!deck) {
      const { data: created, error: dErr } = await c.from('decks')
        .insert({ user_id: uid, name: 'Crossplay Smoke Deck' })
        .select('id').single();
      if (dErr) throw new Error(`deck insert: ${dErr.message}`);
      deck = created;
    }
    const { data: val, error: sErr } = await c.rpc('deck_set_chits', {
      p_deck_id: deck.id,
      p_chits: chitIds.map((id) => ({ chit_id: id, quantity: 2 })),
    });
    if (sErr) throw new Error(`deck_set_chits: ${sErr.message}`);
    assert((val as { is_valid: boolean }).is_valid, `deck must be legal: ${JSON.stringify(val)}`);
    decks.push(deck.id as string);
  }

  console.log('5. queue: A joins (queued), B joins (matched)…');
  const { data: jA, error: jAErr } = await cA.rpc('ccg_queue_join', { p_deck_id: decks[0], p_platform: 'web' });
  if (jAErr) throw new Error(`A join: ${jAErr.message}`);
  assert((jA as { status: string }).status === 'queued', `A should queue, got ${JSON.stringify(jA)}`);

  const { data: jB, error: jBErr } = await cB.rpc('ccg_queue_join', { p_deck_id: decks[1], p_platform: 'arena' });
  if (jBErr) throw new Error(`B join: ${jBErr.message}`);
  const matchId = (jB as { status: string; match_id: string }).match_id;
  assert((jB as { status: string }).status === 'matched' && matchId, `B should match, got ${JSON.stringify(jB)}`);

  const { data: pA } = await cA.rpc('ccg_queue_poll');
  assert((pA as { status: string; match_id?: string }).status === 'matched'
    && (pA as { match_id?: string }).match_id === matchId,
    `A poll should hand over the same match, got ${JSON.stringify(pA)}`);

  console.log(`   match ${matchId}`);

  console.log('6. RLS probe: B must NOT see seat-1 hand cards…');
  const { data: bView } = await cB.from('ccg_match_cards')
    .select('id, owner_seat, zone').eq('match_id', matchId).eq('zone', 'hand');
  assert((bView ?? []).every((r) => (r as { owner_seat: number }).owner_seat === 2),
    `B saw a seat-1 hand card: ${JSON.stringify(bView)}`);

  console.log('7. A plays turn 1 (summon cheapest affordable, else pass)…');
  const { data: handA } = await cA.from('ccg_match_cards')
    .select('id, snap_aura_cost, snap_chit_type').eq('match_id', matchId)
    .eq('zone', 'hand').eq('owner_seat', 1).order('snap_aura_cost');
  const { data: meA } = await cA.from('ccg_match_players')
    .select('aura').eq('match_id', matchId).eq('seat', 1).single();
  const affordable = (handA ?? []).find((h) =>
    (h as { snap_aura_cost: number; snap_chit_type: string }).snap_chit_type === 'creature'
    && (h as { snap_aura_cost: number }).snap_aura_cost <= ((meA as { aura: number })?.aura ?? 0));
  const actions = affordable
    ? [{ type: 'summon', card_id: (affordable as { id: string }).id, position: 1 }, { type: 'end' }]
    : [{ type: 'end' }];
  const { data: turn, error: tErr } = await cA.rpc('ccg_submit_turn', {
    p_match_id: matchId, p_actions: actions,
  });
  if (tErr) throw new Error(`submit_turn: ${tErr.message}`);
  assert((turn as { active_seat: number }).active_seat === 2,
    `turn should pass to seat 2, got ${JSON.stringify(turn)}`);
  console.log(`   turn OK (${affordable ? 'summoned a creature' : 'passed'})`);

  console.log('8. B forfeits → seat 1 wins…');
  const { data: ff, error: fErr } = await cB.rpc('ccg_forfeit_match', { p_match_id: matchId });
  if (fErr) throw new Error(`forfeit: ${fErr.message}`);
  assert((ff as { status: string; winner_seat: number }).status === 'finished'
    && (ff as { winner_seat: number }).winner_seat === 1,
    `forfeit should finish with winner 1, got ${JSON.stringify(ff)}`);

  console.log('9. cleanup…');
  await admin.from('ccg_matches').delete().eq('id', matchId);           // cascades players/cards/events
  for (const [u, d] of [[uA, decks[0]], [uB, decks[1]]] as const) {
    await admin.from('decks').delete().eq('id', d);
    for (const c of chitIds) {
      await admin.rpc('chit_grant', { p_user_id: u, p_chit_id: c, p_quantity: -2, p_reason: 'platform_correction' });
    }
  }
  await admin.from('moment_chits')
    .update({ is_active: false, retired_at: new Date().toISOString(), retired_reason: 'admin' })
    .in('id', chitIds);
  for (const u of [uA, uB]) await admin.auth.admin.deleteUser(u).catch(() => {});

  console.log('\nCROSSPLAY SMOKE OK: queue pair → RLS hand privacy → real turn → forfeit → cleanup');
}

main().catch((e) => {
  console.error(e);
  Deno.exit(1);
});
