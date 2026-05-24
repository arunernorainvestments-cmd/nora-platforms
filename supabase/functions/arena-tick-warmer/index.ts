// arena-tick-warmer: lightweight keep-alive called every 30s by pg_cron.
// Keeps the Supabase connection pool warm so process_arena_tick() has no
// cold-start delay. Does a single cheap query and returns immediately.
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': 'https://noraplatforms.com',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { status: 200, headers: CORS_HEADERS });
  }

  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const authHeader = req.headers.get('authorization') ?? '';
  if (authHeader !== `Bearer ${serviceRoleKey}`) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), {
      status: 401,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  const db = createClient(Deno.env.get('SUPABASE_URL') ?? '', serviceRoleKey, {
    auth: { persistSession: false },
  });

  const { count } = await db
    .from('arena_matches')
    .select('*', { count: 'exact', head: true })
    .eq('state', 'live');

  return new Response(JSON.stringify({ warm: true, live_matches: count ?? 0 }), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
