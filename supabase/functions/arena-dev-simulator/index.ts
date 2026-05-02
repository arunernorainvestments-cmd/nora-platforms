// arena-dev-simulator — Dev-only match simulation tool
//
// BRANCH DECISION (reconnaissance, 2026-05-02):
//   Cannot query live DB from codespace (no service role key in env).
//   Code analysis: migration 026 seeded 20 test creators; migration 027
//   (teardown) was NOT applied per CLAUDE.md. Test creators assumed to exist.
//   Migration 051 (idempotent reseed) applied as safety net.
//   → Branch A: test creators exist with platform_metrics.
//
// SECURITY: Only callable when ALLOW_DEV_TOOLS=true. Returns 403 otherwise.
// MUST NOT be set in production. Never call sync-platform-metrics, OAuth, or
// any function that touches real platform data.
//
// Modes:
//   snapshot  — Creates 2–10 pre_match matches, places backing, calls one tick
//               to flip them live. Returns match IDs.
//   burst     — Inserts additional back events on currently live test matches,
//               calls one tick. Returns tick results per match.
//   full_cycle — Creates one match pre-seeded to resolve immediately on first
//               tick (actual_start set to 6 min ago), verifies pool distribution.
//
// Constraints enforced:
//   match_cycles <= 20 (rejects with 400 if higher)
//   backing_events_per_match <= 10 (rejects with 400 if higher)
//   Only operates on rows where is_test_account = true
//   All token movements logged in token_transactions

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data, null, 2), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}

// Test creator UUIDs: 10000000-0000-0000-0000-000000000001 – …000020
// UUID last group is 12 hex chars.
function testCreatorId(n: number): string {
  return `10000000-0000-0000-0000-${String(n).padStart(12, '0')}`;
}

type SupabaseClient = ReturnType<typeof createClient>;

interface Profile {
  id: string;
  username: string;
  category_1: string;
  subcategory: string | null;
  momentum_score: number;
}

// ── Fetch all 20 test creators with their momentum_score ──────────────────────
// platform_metrics.user_id has no FK to profiles (only platform_connection_id
// is constrained), so PostgREST can't auto-join. Two queries, merged in TS.
async function fetchTestCreators(supabase: SupabaseClient): Promise<Profile[]> {
  const { data: profiles, error: profilesErr } = await supabase
    .from('profiles')
    .select('id, username, category_1, subcategory')
    .eq('is_test_account', true)
    .eq('is_market_maker', true)
    .eq('is_approved', true);

  if (profilesErr) throw new Error(`fetchTestCreators profiles: ${profilesErr.message}`);

  const ids = (profiles ?? []).map((p: Record<string, unknown>) => p.id as string);
  if (ids.length === 0) return [];

  const { data: metrics, error: metricsErr } = await supabase
    .from('platform_metrics')
    .select('user_id, momentum_score')
    .in('user_id', ids);

  if (metricsErr) throw new Error(`fetchTestCreators metrics: ${metricsErr.message}`);

  const momentumByUserId: Record<string, number> = {};
  for (const m of metrics ?? []) {
    const row = m as { user_id: string; momentum_score: number };
    momentumByUserId[row.user_id] = Math.max(momentumByUserId[row.user_id] ?? 0, row.momentum_score ?? 0);
  }

  return (profiles ?? []).map((p: Record<string, unknown>) => ({
    id: p.id as string,
    username: p.username as string,
    category_1: (p.category_1 as string) ?? 'Athlete',
    subcategory: p.subcategory as string | null,
    momentum_score: momentumByUserId[p.id as string] ?? 0,
  }));
}

// ── Create one arena_match + arena_state ──────────────────────────────────────
async function createMatch(
  supabase: SupabaseClient,
  p1: Profile,
  p2: Profile,
  round: number,
  asLive: boolean, // true = insert as 'live' with old actual_start (full_cycle)
): Promise<string> {
  const scheduledStart = new Date(Date.now() - 60_000).toISOString(); // 1 min ago
  const actualStart = asLive
    ? new Date(Date.now() - 6 * 60_000).toISOString() // 6 min ago → resolves on first tick
    : null;

  const { data: match, error: matchErr } = await supabase
    .from('arena_matches')
    .insert({
      round,
      state: asLive ? 'live' : 'pre_match',
      player_1_id: p1.id,
      player_2_id: p2.id,
      player_1_archetype: p1.category_1,
      player_2_archetype: p2.category_1,
      subcategory_p1: p1.subcategory ?? null,
      subcategory_p2: p2.subcategory ?? null,
      momentum_score_p1_at_start: p1.momentum_score,
      momentum_score_p2_at_start: p2.momentum_score,
      scheduled_start: scheduledStart,
      actual_start: actualStart,
    })
    .select('id')
    .single();

  if (matchErr) throw new Error(`createMatch: ${matchErr.message}`);

  const matchId = match.id as string;

  // Start with minor score variance for snapshot (45/55), zero for full_cycle
  const scoreP1 = asLive ? 0 : 45;
  const scoreP2 = asLive ? 0 : 55;

  const { error: stateErr } = await supabase
    .from('arena_state')
    .insert({
      match_id: matchId,
      tick: 0,
      score_p1: scoreP1,
      score_p2: scoreP2,
      flow_rate_p1: 0,
      flow_rate_p2: 0,
      heat_influence_p1: 0,
      heat_influence_p2: 0,
      active_effects: [],
      expired_effects: [],
      suppression_p1: 0,
      suppression_p2: 0,
      momentum_window_p1: false,
      momentum_window_p2: false,
      total_pool_p1: 0,
      total_pool_p2: 0,
    });

  if (stateErr) {
    // Roll back the match row
    await supabase.from('arena_matches').delete().eq('id', matchId);
    throw new Error(`createMatch state: ${stateErr.message}`);
  }

  return matchId;
}

// ── Place backing events via dev_arena_back() SQL helper ──────────────────────
// Returns total tokens placed on each side.
async function placeBackings(
  supabase: SupabaseClient,
  matchId: string,
  p1Id: string,
  p2Id: string,
  backers: Profile[],
  eventsPerMatch: number,
): Promise<{ totalPoolP1: number; totalPoolP2: number; events: Array<{ backer: string; target: string; amount: number }> }> {
  let totalPoolP1 = 0;
  let totalPoolP2 = 0;
  const events: Array<{ backer: string; target: string; amount: number }> = [];

  // 60/40 split: first 60% of events back p1, remaining 40% back p2
  const p1Count = Math.ceil(eventsPerMatch * 0.6);

  for (let i = 0; i < eventsPerMatch; i++) {
    const backer = backers[i % backers.length];
    const targetId = i < p1Count ? p1Id : p2Id;
    // Randomised amount 10–50
    const amount = 10 + Math.floor(Math.random() * 41);

    const { error } = await supabase.rpc('dev_arena_back', {
      p_backer_id: backer.id,
      p_match_id: matchId,
      p_target_id: targetId,
      p_amount: amount,
    });

    if (error) {
      console.warn(`[arena-dev-simulator] backing skipped (${backer.username} → ${targetId}): ${error.message}`);
      continue;
    }

    if (targetId === p1Id) totalPoolP1 += amount;
    else totalPoolP2 += amount;
    events.push({ backer: backer.username, target: targetId === p1Id ? 'p1' : 'p2', amount });
  }

  return { totalPoolP1, totalPoolP2, events };
}

// ── Call process_arena_tick() ─────────────────────────────────────────────────
async function callTick(supabase: SupabaseClient): Promise<void> {
  const { error } = await supabase.rpc('process_arena_tick');
  if (error) throw new Error(`process_arena_tick: ${error.message}`);
}

// ── Poll a match until resolved or max ticks ──────────────────────────────────
async function waitForResolution(
  supabase: SupabaseClient,
  matchId: string,
  maxTicks: number,
): Promise<{ resolved: boolean; ticks: number; state: string }> {
  for (let tick = 0; tick < maxTicks; tick++) {
    await callTick(supabase);

    const { data, error } = await supabase
      .from('arena_matches')
      .select('state')
      .eq('id', matchId)
      .single();

    if (error) throw new Error(`poll match state: ${error.message}`);

    if (data.state === 'resolved') return { resolved: true, ticks: tick + 1, state: 'resolved' };
  }

  return { resolved: false, ticks: maxTicks, state: 'unresolved' };
}

// ════════════════════════════════════════════════════════════════════════════════
// MODE: snapshot
// ════════════════════════════════════════════════════════════════════════════════
async function modeSnapshot(
  supabase: SupabaseClient,
  matchCycles: number,
  backingEventsPerMatch: number,
  round: number,
): Promise<Response> {
  const creators = await fetchTestCreators(supabase);

  // Group by category_1
  const byCategory: Record<string, Profile[]> = {};
  for (const c of creators) {
    if (!byCategory[c.category_1]) byCategory[c.category_1] = [];
    byCategory[c.category_1].push(c);
  }

  // Valid pairs: categories with exactly 2 creators
  const pairs = Object.values(byCategory).filter((g) => g.length >= 2);
  const numMatches = Math.min(matchCycles, pairs.length);

  if (numMatches === 0) {
    return json({ error: 'No same-category test creator pairs found. Run migration 051.' }, 500);
  }

  const matchSummaries: Array<{
    match_id: string;
    p1: string;
    p2: string;
    category: string;
    pool_p1: number;
    pool_p2: number;
    backing_events: Array<{ backer: string; target: string; amount: number }>;
  }> = [];

  for (let i = 0; i < numMatches; i++) {
    const [p1, p2] = pairs[i];
    const matchId = await createMatch(supabase, p1, p2, round, false);

    // Backers are all test creators NOT in this match
    const backers = creators.filter((c) => c.id !== p1.id && c.id !== p2.id);

    const { totalPoolP1, totalPoolP2, events } = await placeBackings(
      supabase, matchId, p1.id, p2.id, backers, backingEventsPerMatch,
    );

    matchSummaries.push({
      match_id: matchId,
      p1: p1.username,
      p2: p2.username,
      category: p1.category_1,
      pool_p1: totalPoolP1,
      pool_p2: totalPoolP2,
      backing_events: events,
    });

    console.log(`[arena-dev-simulator/snapshot] match ${matchId}: ${p1.username} vs ${p2.username}`);
  }

  // One tick call flips all pre_match → live
  await callTick(supabase);

  return json({
    mode: 'snapshot',
    matches_created: matchSummaries.length,
    note: 'All matches now live. Use burst mode to add more activity.',
    matches: matchSummaries,
  });
}

// ════════════════════════════════════════════════════════════════════════════════
// MODE: burst
// ════════════════════════════════════════════════════════════════════════════════
async function modeBurst(
  supabase: SupabaseClient,
  backingEventsPerMatch: number,
): Promise<Response> {
  // Find live matches involving test creators
  const testIds = Array.from({ length: 20 }, (_, i) => testCreatorId(i + 1));

  const { data: liveMatches, error: matchErr } = await supabase
    .from('arena_matches')
    .select('id, player_1_id, player_2_id, player_1_archetype, player_2_archetype')
    .eq('state', 'live')
    .or(`player_1_id.in.(${testIds.join(',')}),player_2_id.in.(${testIds.join(',')})`);

  if (matchErr) return json({ error: matchErr.message }, 500);

  if (!liveMatches || liveMatches.length === 0) {
    return json({
      mode: 'burst',
      note: 'No live test matches found. Run snapshot mode first.',
      matches_updated: 0,
    });
  }

  const creators = await fetchTestCreators(supabase);
  const burstResults: Array<{
    match_id: string;
    events_placed: number;
    pool_p1_added: number;
    pool_p2_added: number;
  }> = [];

  for (const match of liveMatches) {
    const m = match as {
      id: string;
      player_1_id: string;
      player_2_id: string;
    };

    const backers = creators.filter((c) => c.id !== m.player_1_id && c.id !== m.player_2_id);
    const numEvents = 2 + Math.floor(Math.random() * 3); // 2–4 events per match
    const cappedEvents = Math.min(numEvents, backingEventsPerMatch);

    const { totalPoolP1, totalPoolP2, events } = await placeBackings(
      supabase, m.id, m.player_1_id, m.player_2_id, backers, cappedEvents,
    );

    burstResults.push({
      match_id: m.id,
      events_placed: events.length,
      pool_p1_added: totalPoolP1,
      pool_p2_added: totalPoolP2,
    });
  }

  // Single tick advances all live matches
  await callTick(supabase);

  return json({
    mode: 'burst',
    matches_updated: burstResults.length,
    note: 'One tick fired. Matches remain live.',
    matches: burstResults,
  });
}

// ════════════════════════════════════════════════════════════════════════════════
// MODE: full_cycle
// ════════════════════════════════════════════════════════════════════════════════
async function modeFullCycle(
  supabase: SupabaseClient,
  backingEventsPerMatch: number,
  round: number,
): Promise<Response> {
  const creators = await fetchTestCreators(supabase);

  // Pick the Athlete pair (creators 1 & 2) as the default full-cycle match
  const p1 = creators.find((c) => c.username === 'test_athlete_basketball_1');
  const p2 = creators.find((c) => c.username === 'test_athlete_football_1');

  if (!p1 || !p2) {
    return json({ error: 'Test Athlete creators not found. Apply migration 051.' }, 500);
  }

  // Insert as 'live' with actual_start 6 minutes ago — resolves on first tick
  const matchId = await createMatch(supabase, p1, p2, round, true);

  const backers = creators.filter((c) => c.id !== p1.id && c.id !== p2.id);
  const { totalPoolP1, totalPoolP2, events: backingEvents } = await placeBackings(
    supabase, matchId, p1.id, p2.id, backers, backingEventsPerMatch,
  );
  const totalPool = totalPoolP1 + totalPoolP2;

  console.log(`[arena-dev-simulator/full_cycle] match ${matchId} — pool: ${totalPool} (p1:${totalPoolP1} p2:${totalPoolP2})`);

  // Run ticks until resolved, max 100
  const { resolved, ticks } = await waitForResolution(supabase, matchId, 100);

  if (!resolved) {
    return json({
      mode: 'full_cycle',
      match_id: matchId,
      error: 'Match did not resolve within 100 ticks — check process_arena_tick() logs.',
      ticks_called: ticks,
      pool: { total: totalPool, p1: totalPoolP1, p2: totalPoolP2 },
      backing_events: backingEvents,
    }, 500);
  }

  // ── Fetch final match state ────────────────────────────────────────────────
  const { data: finalMatch, error: finalErr } = await supabase
    .from('arena_matches')
    .select('winner_id, final_score_p1, final_score_p2, state')
    .eq('id', matchId)
    .single();

  if (finalErr) return json({ error: finalErr.message }, 500);

  // ── Verify pool distribution ───────────────────────────────────────────────
  const { data: winTxns, error: txnErr } = await supabase
    .from('token_transactions')
    .select('user_id, amount')
    .eq('reference_id', matchId)
    .eq('type', 'arena_win');

  if (txnErr) return json({ error: txnErr.message }, 500);

  const actualPaid = (winTxns ?? []).reduce((sum: number, t: { amount: number }) => sum + t.amount, 0);
  const expectedWinnerPool = Math.floor(totalPool * 0.9);  // 90% distributed to winning backers
  const expectedCreatorCut = Math.floor(totalPool * 0.05); // 5% to winning creator
  const expectedPaid = expectedWinnerPool + expectedCreatorCut;
  const platformRetained = totalPool - actualPaid;
  // The tick distributes winner_pool per-backer with FLOOR(), so up to
  // num_winning_backers tokens can be lost to rounding and kept by platform.
  // A discrepancy <= backing_events_per_match is normal and expected.
  const numWinningBackers = backingEvents.filter((e) => {
    const winnerId = finalMatch.winner_id;
    return (winnerId === p1.id && e.target === 'p1') ||
           (winnerId === p2.id && e.target === 'p2');
  }).length;
  const distributionOk = Math.abs(actualPaid - expectedPaid) <= numWinningBackers;

  const winner = finalMatch.winner_id === p1.id ? p1.username : p2.username;

  if (!distributionOk) {
    console.warn(
      `[arena-dev-simulator/full_cycle] Distribution discrepancy: ` +
      `expected ${expectedPaid} paid (${expectedWinnerPool} backers + ${expectedCreatorCut} creator), ` +
      `actual ${actualPaid} paid.`
    );
  }

  return json({
    mode: 'full_cycle',
    match_id: matchId,
    ticks_to_resolve: ticks,
    result: {
      winner,
      winner_id: finalMatch.winner_id,
      final_score_p1: finalMatch.final_score_p1,
      final_score_p2: finalMatch.final_score_p2,
    },
    pool: {
      total: totalPool,
      p1: totalPoolP1,
      p2: totalPoolP2,
    },
    distribution: {
      expected_winner_pool: expectedWinnerPool,
      expected_creator_cut: expectedCreatorCut,
      expected_platform_rake: totalPool - expectedPaid,
      actual_paid_out: actualPaid,
      platform_retained: platformRetained,
      ok: distributionOk,
      discrepancy: distributionOk
        ? null
        : `expected ~${expectedPaid}, got ${actualPaid} (delta ${Math.abs(actualPaid - expectedPaid)}, tolerance ${numWinningBackers})`,
    },
    backing_events: backingEvents,
  });
}

// ════════════════════════════════════════════════════════════════════════════════
// Entry point
// ════════════════════════════════════════════════════════════════════════════════
Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  if (Deno.env.get('ALLOW_DEV_TOOLS') !== 'true') {
    return json({ error: 'Dev tools are not enabled in this environment.' }, 403);
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    { auth: { persistSession: false } },
  );

  let body: {
    mode?: string;
    match_cycles?: number;
    backing_events_per_match?: number;
    round?: number;
  };
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Invalid JSON body' }, 400);
  }

  const {
    mode = 'snapshot',
    match_cycles = 2,
    backing_events_per_match = 3,
    round = 1,
  } = body;

  if (!['snapshot', 'burst', 'full_cycle'].includes(mode)) {
    return json({ error: 'mode must be snapshot | burst | full_cycle' }, 400);
  }
  if (match_cycles > 20) {
    return json({ error: 'match_cycles cannot exceed 20' }, 400);
  }
  if (backing_events_per_match > 10) {
    return json({ error: 'backing_events_per_match cannot exceed 10' }, 400);
  }
  if (![1, 2, 3].includes(round)) {
    return json({ error: 'round must be 1, 2, or 3' }, 400);
  }

  try {
    switch (mode) {
      case 'snapshot':
        return await modeSnapshot(supabase, match_cycles, backing_events_per_match, round);
      case 'burst':
        return await modeBurst(supabase, backing_events_per_match);
      case 'full_cycle':
        return await modeFullCycle(supabase, backing_events_per_match, round);
      default:
        return json({ error: 'Unknown mode' }, 400);
    }
  } catch (err) {
    const msg = err instanceof Error ? err.message : String(err);
    console.error(`[arena-dev-simulator] unhandled error: ${msg}`);
    return json({ error: msg }, 500);
  }
});
