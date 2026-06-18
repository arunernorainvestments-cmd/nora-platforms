// supabase/functions/nora-arena-api-market/index.ts
//
// doc6 mobile-API convenience endpoint: the Arena prediction market(s) linked to
// a battle match, for the spectator bet bottom-sheet. Thin read over `markets`
// filtered by battle_match_id. Pools are public data. Deploy WITH jwt
// verification (the spectator app session is always present).
//
// Query params:
//   battle_match_id  — required; the live battle to fetch the market for
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'GET') return json({ error: 'Method not allowed' }, 405);

  try {
    const battleMatchId = new URL(req.url).searchParams.get('battle_match_id');
    if (!battleMatchId) return json({ error: 'battle_match_id is required' }, 400);

    const service = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    // A battle has one open battle_outcome market (team_1 = yes_pool, team_2 =
    // no_pool — see migration 100). Return all rows for the match so a resolved
    // match still surfaces its settled pools.
    const { data, error } = await service
      .from('markets')
      .select('id, title, status, resolution_type, yes_pool, no_pool, end_at, battle_match_id')
      .eq('battle_match_id', battleMatchId)
      .eq('resolution_type', 'battle_outcome')
      .order('end_at', { ascending: false });
    if (error) {
      console.error('nora-arena-api-market lookup error:', JSON.stringify(error));
      return json({ error: 'lookup_failed' }, 500);
    }

    return json({
      battle_match_id: battleMatchId,
      markets: (data ?? []).map((m) => ({
        market_id: m.id,
        title: m.title,
        status: m.status,
        team_1_pool: m.yes_pool ?? 0,
        team_2_pool: m.no_pool ?? 0,
        total_pool: ((m.yes_pool as number | null) ?? 0) + ((m.no_pool as number | null) ?? 0),
        end_at: m.end_at,
      })),
    }, 200);
  } catch (err) {
    console.error('nora-arena-api-market error:', err);
    return json({ error: 'Internal server error' }, 500);
  }
});
