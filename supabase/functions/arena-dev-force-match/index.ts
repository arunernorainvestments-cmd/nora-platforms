// arena-dev-force-match — Phase C balance testing tool
//
// SECURITY: Only callable when ALLOW_DEV_TOOLS=true in the function's environment.
// This variable MUST NOT be set in production. Returns 403 if not set.
//
// POST body: { p1_user_id: string, p2_user_id: string, round?: 1|2|3 }
// Returns:   { match_id: string, player_1_archetype: string, player_2_archetype: string,
//              scheduled_start: string }
//
// Behavior:
//   - Bypasses normal matchmaker eligibility (cross-category allowed for testing)
//   - scheduled_start = now() + 10 seconds (faster than normal 30s for dev speed)
//   - Inserts arena_matches + arena_state; tick loop flips pre_match → live
//   - Does not enforce same-category requirement (Round 1 normally requires same category)

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  // ── Guard: refuse if dev tools are not explicitly enabled ────────────────
  if (Deno.env.get('ALLOW_DEV_TOOLS') !== 'true') {
    return json({ error: 'Dev tools are not enabled in this environment.' }, 403);
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    { auth: { persistSession: false } },
  );

  let body: { p1_user_id?: string; p2_user_id?: string; round?: number };
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Invalid request body' }, 400);
  }

  const { p1_user_id, p2_user_id, round = 1 } = body;

  if (!p1_user_id || !p2_user_id) {
    return json({ error: 'p1_user_id and p2_user_id are required' }, 400);
  }
  if (p1_user_id === p2_user_id) {
    return json({ error: 'Players must be different' }, 400);
  }
  if (![1, 2, 3].includes(round)) {
    return json({ error: 'round must be 1, 2, or 3' }, 400);
  }

  // ── Load player profiles ─────────────────────────────────────────────────
  const { data: players, error: playersErr } = await supabase
    .from('profiles')
    .select('id, username, category_1, subcategory, is_market_maker')
    .in('id', [p1_user_id, p2_user_id]);

  if (playersErr) return json({ error: playersErr.message }, 500);
  if (!players || players.length !== 2) {
    return json({ error: 'One or both players not found' }, 404);
  }

  const p1 = players.find((p: { id: string }) => p.id === p1_user_id);
  const p2 = players.find((p: { id: string }) => p.id === p2_user_id);

  if (!p1 || !p2) return json({ error: 'Player lookup failed' }, 500);

  // is_market_maker check (both must be eligible creators)
  if (!p1.is_market_maker) return json({ error: `${p1.username} is not a Market Maker` }, 400);
  if (!p2.is_market_maker) return json({ error: `${p2.username} is not a Market Maker` }, 400);

  const p1Archetype = (p1.category_1 as string | null) ?? 'athlete';
  const p2Archetype = (p2.category_1 as string | null) ?? 'athlete';

  const scheduledStart = new Date(Date.now() + 10_000).toISOString(); // 10s from now

  // ── Insert arena_matches ─────────────────────────────────────────────────
  const { data: match, error: matchErr } = await supabase
    .from('arena_matches')
    .insert({
      round,
      state: 'pre_match',
      player_1_id: p1_user_id,
      player_2_id: p2_user_id,
      player_1_archetype: p1Archetype,
      player_2_archetype: p2Archetype,
      subcategory_p1: p1.subcategory ?? null,
      subcategory_p2: p2.subcategory ?? null,
      scheduled_start: scheduledStart,
    })
    .select('id')
    .single();

  if (matchErr) return json({ error: matchErr.message }, 500);

  const matchId = match.id as string;

  // ── Insert initial arena_state ───────────────────────────────────────────
  const { error: stateErr } = await supabase
    .from('arena_state')
    .insert({
      match_id: matchId,
      tick: 0,
      score_p1: 0,
      score_p2: 0,
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
    // Roll back match if state insert fails
    await supabase.from('arena_matches').delete().eq('id', matchId);
    return json({ error: stateErr.message }, 500);
  }

  console.log(
    `[arena-dev-force-match] Created match ${matchId}: ` +
    `${p1.username} (${p1Archetype}/${p1.subcategory ?? 'none'}) vs ` +
    `${p2.username} (${p2Archetype}/${p2.subcategory ?? 'none'}) — round ${round}`
  );

  return json({
    match_id: matchId,
    player_1: { id: p1_user_id, username: p1.username, archetype: p1Archetype, subcategory: p1.subcategory },
    player_2: { id: p2_user_id, username: p2.username, archetype: p2Archetype, subcategory: p2.subcategory },
    round,
    scheduled_start: scheduledStart,
    note: 'Match starts ~10s from creation. Tick loop flips pre_match → live.',
  });
});
