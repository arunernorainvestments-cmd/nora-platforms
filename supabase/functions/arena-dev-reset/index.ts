// arena-dev-reset — Clears arena state for test creators only
//
// SECURITY: Only callable when ALLOW_DEV_TOOLS=true. Returns 403 otherwise.
// MUST NOT be set in production.
//
// Deletes arena rows tied to test creators (is_test_account=true) in FK order:
//   arena_ability_uses → arena_events → arena_match_telemetry
//   → arena_state → arena_matches
// Then resets token_balances to 1000 and zeros arena_weekly_points.
//
// Does NOT: touch real user rows, modify display_score or heat_score,
//           drop schema, or touch waitlist/markets/bets tables.

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

type SupabaseClient = ReturnType<typeof createClient>;

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  if (Deno.env.get('ALLOW_DEV_TOOLS') !== 'true') {
    return json({ error: 'Dev tools are not enabled in this environment.' }, 403);
  }

  const supabase: SupabaseClient = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    { auth: { persistSession: false } },
  );

  // ── 1. Collect test creator IDs ────────────────────────────────────────────
  const { data: testProfiles, error: profilesErr } = await supabase
    .from('profiles')
    .select('id')
    .eq('is_test_account', true);

  if (profilesErr) return json({ error: profilesErr.message }, 500);

  const testIds: string[] = (testProfiles ?? []).map((p: { id: string }) => p.id);

  if (testIds.length === 0) {
    return json({
      error: 'No test creators found. Apply migration 051 first.',
      hint: 'POST to arena-dev-simulator after applying the migration.',
    }, 404);
  }

  // ── 2. Count matches before deletion (for reporting) ─────────────────────
  const { count: matchCount } = await supabase
    .from('arena_matches')
    .select('id', { count: 'exact', head: true })
    .or(`player_1_id.in.(${testIds.join(',')}),player_2_id.in.(${testIds.join(',')})`) as { count: number | null };

  const counts: Record<string, number> = {
    arena_ability_uses: 0,
    arena_events: 0,
    arena_round3_results: 0,
    arena_match_telemetry: 0,
    arena_state: 0,
    arena_matches: 0,
    arena_weekly_points_zeroed: 0,
    token_balances_reset: 0,
    compensating_transactions: 0,
  };

  // ── 3. Delete arena rows via server-side SQL function ─────────────────────
  // Uses dev_arena_reset_matches() to avoid PostgREST URL length limits that
  // would arise from passing thousands of match IDs through .in() from the
  // edge function. The SQL function does the cleanup in a single roundtrip
  // using DELETE ... WHERE player_1_id = ANY(p_test_ids).
  const { data: resetResult, error: resetErr } = await supabase
    .rpc('dev_arena_reset_matches', { p_test_ids: testIds });

  if (resetErr) {
    console.warn(`[arena-dev-reset] dev_arena_reset_matches: ${resetErr.message}`);
  } else if (resetResult && resetResult.length > 0) {
    const r = resetResult[0] as {
      deleted_ability_uses: number;
      deleted_events: number;
      deleted_round3_results: number;
      deleted_telemetry: number;
      deleted_state: number;
      deleted_matches: number;
    };
    counts.arena_ability_uses = r.deleted_ability_uses;
    counts.arena_events = r.deleted_events;
    counts.arena_round3_results = r.deleted_round3_results;
    counts.arena_match_telemetry = r.deleted_telemetry;
    counts.arena_state = r.deleted_state;
    counts.arena_matches = r.deleted_matches;
  }

  // ── 4. Zero arena_weekly_points for test creators ─────────────────────────
  const { data: wpUpdated, error: wpErr } = await supabase
    .from('arena_weekly_points')
    .update({ points: 0 })
    .in('user_id', testIds)
    .select('user_id');

  if (wpErr) {
    console.warn(`[arena-dev-reset] arena_weekly_points zero: ${wpErr.message}`);
  } else {
    counts.arena_weekly_points_zeroed = (wpUpdated ?? []).length;
  }

  // ── 5. Zero momentum_score on platform_metrics for test creators ──────────
  // (Only arena_monday-rollover and match resolution normally touch this;
  //  resetting here so subsequent simulator runs start from a clean baseline.)
  await supabase
    .from('platform_metrics')
    .update({ momentum_score: 0 })
    .in('user_id', testIds);

  // ── 6. Reset token balances to 1000 ───────────────────────────────────────
  const { data: balUpdated, error: balErr } = await supabase
    .from('token_balances')
    .update({
      available_tokens: 1000,
      lifetime_earned: 1000,
      lifetime_spent: 0,
    })
    .in('user_id', testIds)
    .select('user_id');

  if (balErr) {
    console.warn(`[arena-dev-reset] token_balances reset: ${balErr.message}`);
  } else {
    counts.token_balances_reset = (balUpdated ?? []).length;
  }

  // ── 7. Compensating transaction per creator (audit trail) ─────────────────
  const compensatingTxns = testIds.map((uid: string) => ({
    user_id: uid,
    type: 'refund',
    amount: 1000,
    description: 'Dev reset: token balance restored to 1000',
  }));

  if (compensatingTxns.length > 0) {
    const { data: txnInserted, error: txnErr } = await supabase
      .from('token_transactions')
      .insert(compensatingTxns)
      .select('id');

    if (txnErr) {
      console.warn(`[arena-dev-reset] compensating transactions: ${txnErr.message}`);
    } else {
      counts.compensating_transactions = (txnInserted ?? []).length;
    }
  }

  console.log(`[arena-dev-reset] complete — ${JSON.stringify(counts)}`);

  return json({
    success: true,
    test_creators: testIds.length,
    arena_matches_cleared: matchCount ?? counts.arena_matches,
    deleted: {
      arena_ability_uses: counts.arena_ability_uses,
      arena_events: counts.arena_events,
      arena_round3_results: counts.arena_round3_results,
      arena_match_telemetry: counts.arena_match_telemetry,
      arena_state: counts.arena_state,
      arena_matches: counts.arena_matches,
    },
    arena_weekly_points_zeroed: counts.arena_weekly_points_zeroed,
    momentum_score_zeroed: testIds.length,
    token_balances_reset_to_1000: counts.token_balances_reset,
    compensating_transactions_inserted: counts.compensating_transactions,
    note: 'Real user data untouched. display_score and heat_score unchanged.',
  });
});
