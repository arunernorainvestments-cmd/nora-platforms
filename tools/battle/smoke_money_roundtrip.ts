// tools/battle/smoke_money_roundtrip.ts — P7 7.5: the sim-USD real-money
// round-trip that has never been exercised end-to-end (migs 132–134 + 145).
//
// Four throwaway smoke users against PROD (all is_test_account — HR 15):
//   P1/P2 (combatants, sim-KYC'd) build legal 20-card decks via deck_set_chits
//   and pair through the REAL crossplay queue (this doubles as the P7 deck-entry
//   e2e) → G-MON creates the USD battle_outcome market (both KYC'd) →
//   B1/B2 (spectators, sim-KYC'd) place USD bets ($10 team_1 / $6 team_2) →
//   P1 summons (a chit is PLAYED) → P2 forfeits → the settle trigger splits the
//   16.00 pool per ccg_* config: predictors .80, winner .06, loser .02,
//   creator .02 → moment-OWNERS of played chits, passive .05 → holders.
//   Every credit is asserted to the cent, then full cleanup.
//
// Guards it exercises on the way: combatants CANNOT bet on their own match
// (Hard Rule 26) and a non-KYC user cannot bet.
//
// Run:  SUPABASE_URL=https://<ref>.supabase.co \
//       SERVICE_KEY=... ANON_KEY=... [MGMT_TOKEN=...] \
//       deno run --allow-net --allow-env tools/battle/smoke_money_roundtrip.ts

import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';

const url = Deno.env.get('SUPABASE_URL')!;
const serviceKey = Deno.env.get('SERVICE_KEY')!;
const anonKey = Deno.env.get('ANON_KEY')!;
if (!url || !serviceKey || !anonKey) throw new Error('SUPABASE_URL/SERVICE_KEY/ANON_KEY required');

const admin = createClient(url, serviceKey, { auth: { persistSession: false } });
const PASS = 'smoke-' + crypto.randomUUID();
const EMAILS = [
  'money-smoke-p1@noraplatforms.com', 'money-smoke-p2@noraplatforms.com',
  'money-smoke-b1@noraplatforms.com', 'money-smoke-b2@noraplatforms.com',
];

function assert(cond: unknown, msg: string): asserts cond {
  if (!cond) throw new Error(`SMOKE FAIL: ${msg}`);
}

// GoTrue admin listUsers 500s on this project (2026-07-11 finding) — recover an
// existing user's id via a management-API query instead.
async function ensureUser(email: string): Promise<string> {
  const { data, error } = await admin.auth.admin.createUser({
    email, password: PASS, email_confirm: true,
  });
  if (data?.user) return data.user.id;
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

async function signIn(email: string): Promise<SupabaseClient> {
  const c = createClient(url, anonKey, { auth: { persistSession: false } });
  const { error } = await c.auth.signInWithPassword({ email, password: PASS });
  if (error) throw new Error(`sign-in ${email}: ${error.message}`);
  return c;
}

async function simBalance(u: string): Promise<number> {
  const { data } = await admin.from('sim_usd_balances')
    .select('balance_usd_cents').eq('user_id', u).maybeSingle();
  return Number(data?.balance_usd_cents ?? 0);
}

async function main() {
  console.log('1. users (2 players + 2 bettors, test-flagged, sim-KYC)…');
  const [uP1, uP2, uB1, uB2] = [
    await ensureUser(EMAILS[0]), await ensureUser(EMAILS[1]),
    await ensureUser(EMAILS[2]), await ensureUser(EMAILS[3]),
  ];
  await admin.from('profiles').update({ is_test_account: true })
    .in('id', [uP1, uP2, uB1, uB2]);
  // Players must be KYC'd for G-MON; bettors for real-money eligibility.
  // B2 stays un-KYC'd until we've proven the eligibility guard.
  for (const u of [uP1, uP2, uB1]) {
    const { error } = await admin.rpc('kyc_simulate_approve', { p_user_id: u });
    if (error) throw new Error(`kyc_simulate_approve: ${error.message}`);
  }

  console.log('2. catalog chits ×10, each tethered to a P1-owned moment…');
  const chitIds: string[] = [];
  for (let i = 0; i < 10; i++) {
    const { data, error } = await admin.rpc('create_moment_chit', {
      p_name: `Money Smoke ${i + 1}`, p_family: 'athlete',
      p_chit_type: 'creature', p_tier: 'F',
    });
    if (error) throw new Error(`create_moment_chit: ${error.message}`);
    chitIds.push(data as string);
  }
  // The creator-royalty slice pays moment-OWNERS of chits actually played —
  // tether every chit to a P1-owned moment so whichever card gets summoned,
  // the royalty target is deterministic ("summon your friend, your friend earns").
  const momentIds: string[] = [];
  for (const c of chitIds) {
    const { data: m, error: mErr } = await admin.from('moments')
      .insert({ owner_user_id: uP1 }).select('id').single();
    if (mErr) throw new Error(`moment insert: ${mErr.message}`);
    momentIds.push(m.id as string);
    const { error: lErr } = await admin.from('moment_chits')
      .update({ moment_id: m.id }).eq('id', c);
    if (lErr) throw new Error(`chit link: ${lErr.message}`);
  }
  for (const u of [uP1, uP2]) {
    for (const c of chitIds) {
      const { error } = await admin.rpc('chit_grant', {
        p_user_id: u, p_chit_id: c, p_quantity: 2, p_reason: 'event',
      });
      if (error) throw new Error(`chit_grant: ${error.message}`);
    }
  }

  console.log('3. decks via deck_set_chits + crossplay queue pair (deck-entry e2e)…');
  const cP1 = await signIn(EMAILS[0]);
  const cP2 = await signIn(EMAILS[1]);
  const decks: string[] = [];
  for (const c of [cP1, cP2]) {
    const uid = (await c.auth.getUser()).data.user!.id;
    let { data: deck } = await c.from('decks').select('id')
      .eq('user_id', uid).eq('name', 'Money Smoke Deck').maybeSingle();
    if (!deck) {
      const { data: created, error: dErr } = await c.from('decks')
        .insert({ user_id: uid, name: 'Money Smoke Deck' }).select('id').single();
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
  const { data: j1, error: j1Err } = await cP1.rpc('ccg_queue_join',
    { p_deck_id: decks[0], p_platform: 'web' });
  if (j1Err) throw new Error(`P1 join: ${j1Err.message}`);
  assert((j1 as { status: string }).status === 'queued', `P1 should queue: ${JSON.stringify(j1)}`);
  const { data: j2, error: j2Err } = await cP2.rpc('ccg_queue_join',
    { p_deck_id: decks[1], p_platform: 'arena' });
  if (j2Err) throw new Error(`P2 join: ${j2Err.message}`);
  const matchId = (j2 as { match_id: string }).match_id;
  assert((j2 as { status: string }).status === 'matched' && matchId,
    `P2 should match: ${JSON.stringify(j2)}`);
  await cP1.rpc('ccg_queue_poll'); // consume P1's queue row
  console.log(`   match ${matchId}`);

  console.log('4. G-MON: outcome market (both players KYC-verified)…');
  const { data: mkt, error: mktErr } = await admin.rpc('ccg_create_outcome_market',
    { p_match_id: matchId });
  if (mktErr) throw new Error(`create market: ${mktErr.message}`);
  assert(mkt, 'G-MON should CREATE the market for a both-KYC match');
  const marketId = mkt as string;
  const { data: mFlag } = await admin.from('ccg_matches')
    .select('is_monetized').eq('id', matchId).single();
  assert(mFlag?.is_monetized === true, 'match must be stamped is_monetized');

  console.log('5. guards: combatant bet + non-KYC bet must both be rejected…');
  const { error: combatantBet } = await cP1.rpc('ccg_place_bet',
    { p_market_id: marketId, p_position: 'team_1', p_amount_dollars: 1 });
  assert(combatantBet && /one role per match|Combatants/i.test(combatantBet.message),
    `combatant bet must RAISE the one-role error, got: ${combatantBet?.message}`);
  const cB2 = await signIn(EMAILS[3]);           // B2 not yet KYC'd
  const { error: nokycBet } = await cB2.rpc('ccg_place_bet',
    { p_market_id: marketId, p_position: 'team_2', p_amount_dollars: 1 });
  assert(nokycBet && /eligible/i.test(nokycBet.message),
    `non-KYC bet must RAISE eligibility, got: ${nokycBet?.message}`);

  console.log('6. bets: B1 $10 on team_1, B2 (now KYC) $6 on team_2…');
  {
    const { error } = await admin.rpc('kyc_simulate_approve', { p_user_id: uB2 });
    if (error) throw new Error(`kyc B2: ${error.message}`);
  }
  const cB1 = await signIn(EMAILS[2]);
  const { error: b1Err } = await cB1.rpc('ccg_place_bet',
    { p_market_id: marketId, p_position: 'team_1', p_amount_dollars: 10 });
  if (b1Err) throw new Error(`B1 bet: ${b1Err.message}`);
  const { error: b2Err } = await cB2.rpc('ccg_place_bet',
    { p_market_id: marketId, p_position: 'team_2', p_amount_dollars: 6 });
  if (b2Err) throw new Error(`B2 bet: ${b2Err.message}`);

  const { data: pools } = await admin.from('markets')
    .select('usd_yes_pool_cents, usd_no_pool_cents').eq('id', marketId).single();
  assert(Number(pools?.usd_yes_pool_cents) === 1000 && Number(pools?.usd_no_pool_cents) === 600,
    `pools must be 1000/600 cents, got ${JSON.stringify(pools)}`);

  // Balances BEFORE settlement (seed 1,000,000¢; bettors already debited).
  const before = {
    p1: await simBalance(uP1), p2: await simBalance(uP2),
    b1: await simBalance(uB1), b2: await simBalance(uB2),
  };
  assert(before.b1 === 1000000 - 1000, `B1 must be debited 1000¢ (got ${before.b1})`);
  assert(before.b2 === 1000000 - 600, `B2 must be debited 600¢ (got ${before.b2})`);

  console.log('7. P1 summons (a chit is PLAYED) → P2 forfeits → settle trigger…');
  const { data: hand } = await cP1.from('ccg_match_cards')
    .select('id, snap_aura_cost, snap_chit_type').eq('match_id', matchId)
    .eq('zone', 'hand').eq('owner_seat', 1).order('snap_aura_cost');
  const { data: me } = await cP1.from('ccg_match_players')
    .select('aura').eq('match_id', matchId).eq('seat', 1).single();
  const affordable = (hand ?? []).find((h) =>
    (h as { snap_chit_type: string }).snap_chit_type === 'creature'
    && (h as { snap_aura_cost: number }).snap_aura_cost <= ((me as { aura: number })?.aura ?? 0));
  assert(affordable, 'P1 must be able to summon an F-tier creature on turn 1');
  const { error: tErr } = await cP1.rpc('ccg_submit_turn', {
    p_match_id: matchId,
    p_actions: [
      { type: 'summon', card_id: (affordable as { id: string }).id, position: 1 },
      { type: 'end' },
    ],
  });
  if (tErr) throw new Error(`submit_turn: ${tErr.message}`);

  const { data: ff, error: fErr } = await cP2.rpc('ccg_forfeit_match', { p_match_id: matchId });
  if (fErr) throw new Error(`forfeit: ${fErr.message}`);
  assert((ff as { winner_seat: number }).winner_seat === 1,
    `winner must be seat 1: ${JSON.stringify(ff)}`);

  console.log('8. settlement assertions (pool 1600¢, split .80/.06/.02/.02/.05)…');
  const { data: resolved } = await admin.from('markets')
    .select('status, resolution_result').eq('id', marketId).single();
  assert(resolved?.status === 'resolved' && resolved?.resolution_result === 'team_1',
    `market must resolve team_1, got ${JSON.stringify(resolved)}`);

  const after = {
    p1: await simBalance(uP1), p2: await simBalance(uP2),
    b1: await simBalance(uB1), b2: await simBalance(uB2),
  };
  // Predictors: 1280 → B1 alone (stake 1000/1000). Net B1 = -1000 + 1280 = +280.
  assert(after.b1 - 1000000 === 280,
    `B1 must net +280¢ (won 1280 on a 1000 stake), got ${after.b1 - 1000000}`);
  assert(after.b2 - 1000000 === -600, `B2 must net -600¢, got ${after.b2 - 1000000}`);
  // Players: winner 96 + creator 32 (P1 owns every played chit's moment) +
  // passive 40 (holds 2 of 4 copies of the played chit) = 168. Loser: 32 + 40.
  assert(after.p1 - before.p1 === 168,
    `P1 must gain 96+32+40=168¢, got ${after.p1 - before.p1}`);
  assert(after.p2 - before.p2 === 72,
    `P2 must gain 32+40=72¢, got ${after.p2 - before.p2}`);

  const { data: bets } = await admin.from('bets')
    .select('user_id, status').eq('market_id', marketId);
  assert((bets ?? []).find((b) => b.user_id === uB1)?.status === 'won', 'B1 bet must be won');
  assert((bets ?? []).find((b) => b.user_id === uB2)?.status === 'lost', 'B2 bet must be lost');

  const { data: royalty } = await admin.from('sim_usd_transactions')
    .select('id').eq('user_id', uP1).eq('reference_id', marketId)
    .like('description', '%moment owner%');
  assert((royalty ?? []).length === 1, 'P1 must have exactly one moment-owner royalty credit');

  console.log('9. cleanup…');
  await admin.from('bets').delete().eq('market_id', marketId);
  await admin.from('markets').delete().eq('id', marketId);
  await admin.from('ccg_matches').delete().eq('id', matchId);
  for (const [u, d] of [[uP1, decks[0]], [uP2, decks[1]]] as const) {
    await admin.from('decks').delete().eq('id', d);
    for (const c of chitIds) {
      await admin.rpc('chit_grant', {
        p_user_id: u, p_chit_id: c, p_quantity: -2, p_reason: 'platform_correction',
      });
    }
  }
  await admin.from('moment_chits')
    .update({ is_active: false, retired_at: new Date().toISOString(), retired_reason: 'admin' })
    .in('id', chitIds);
  await admin.from('moments').delete().in('id', momentIds);
  for (const u of [uP1, uP2, uB1, uB2]) {
    await admin.auth.admin.deleteUser(u).catch(() => {});
  }

  console.log('\nMONEY ROUND-TRIP SMOKE OK: deck-entry pair → G-MON market → guarded USD bets'
    + ' → played-chit royalty + passive credits + predictor payout, all to the cent');
}

main().catch((e) => {
  console.error(e);
  Deno.exit(1);
});
