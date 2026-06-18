// supabase/functions/nora-arena-api-spotlight/index.ts
//
// doc6 mobile-API convenience endpoint: the Discover tab payload — Arena
// Champions + Top Movers + current weekly-poll leaders, in one call.
//
// Champions/Top Movers are NOT recomputed here: compute-spotlight is the single
// producer of both (Hard Rule 19). This wrapper proxies it and appends the poll
// leaders so the mobile Discover tab loads in one round-trip. Degrades to empty
// sections rather than failing the whole response. Deploy WITH jwt verification.
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

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;

  // ── Champions + Top Movers: proxy the single producer (Hard Rule 19) ──
  let champions: unknown[] = [];
  let topMovers: unknown[] = [];
  try {
    const res = await fetch(`${supabaseUrl}/functions/v1/compute-spotlight`, {
      method: 'GET',
      headers: { Authorization: `Bearer ${anonKey}`, apikey: anonKey },
    });
    if (res.ok) {
      const data = await res.json();
      champions = Array.isArray(data?.champions) ? data.champions : [];
      topMovers = Array.isArray(data?.top_movers) ? data.top_movers : [];
    } else {
      console.error('nora-arena-api-spotlight: compute-spotlight returned', res.status);
    }
  } catch (e) {
    console.error('nora-arena-api-spotlight: compute-spotlight fetch failed:', e);
  }

  // ── Poll leaders: top 5 of the current open weekly poll ──
  let pollLeaders: unknown[] = [];
  try {
    const service = createClient(supabaseUrl, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
    const { data: poll } = await service
      .from('weekly_polls')
      .select('id, title, closes_at')
      .eq('status', 'open')
      .order('closes_at', { ascending: false })
      .limit(1)
      .maybeSingle();
    if (poll) {
      const { data: options } = await service
        .from('poll_options')
        .select('creator_id, display_name, image_url, archetype, weighted_vote_total, current_rank')
        .eq('poll_id', poll.id)
        .order('weighted_vote_total', { ascending: false })
        .limit(5);
      pollLeaders = options ?? [];
    }
  } catch (e) {
    console.error('nora-arena-api-spotlight: poll leaders fetch failed:', e);
  }

  return json({
    champions,
    top_movers: topMovers,
    poll_leaders: pollLeaders,
  }, 200);
});
