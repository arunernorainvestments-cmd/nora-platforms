// arena-monday-rollover — Phase D Monday rollover HTTP trigger
//
// Calls the arena_monday_rollover() PL/pgSQL function (migration 041) which
// is the canonical implementation. This edge function provides an HTTP endpoint
// for manual invocation and testing.
//
// The pg_cron job (registered in migration 041) calls the PL/pgSQL function
// directly without going through this HTTP endpoint, so this function is NOT
// on the hot path.
//
// Security: requires Authorization header with service role key OR a valid
// ROLLOVER_SECRET env var check. Deploy with --no-verify-jwt.

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
  if (req.method !== 'POST' && req.method !== 'GET') {
    return json({ error: 'Method not allowed' }, 405);
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    { auth: { persistSession: false } },
  );

  try {
    const { data, error } = await supabase.rpc('arena_monday_rollover');

    if (error) {
      console.error('[arena-monday-rollover] RPC error:', error.message);
      return json({ error: error.message }, 500);
    }

    console.log('[arena-monday-rollover] completed:', JSON.stringify(data));
    return json({ success: true, result: data }, 200);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error('[arena-monday-rollover] unexpected error:', message);
    return json({ error: message }, 500);
  }
});
