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

// Cache total count for 30s — position changes slowly enough.
let cachedCount: number | null = null;
let cacheExpiresAt = 0;
const CACHE_TTL_MS = 30_000;

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== 'GET' && req.method !== 'POST') {
    return json({ error: 'Method not allowed' }, 405);
  }

  if (cachedCount !== null && Date.now() < cacheExpiresAt) {
    return json({ total: cachedCount });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    { auth: { persistSession: false } },
  );

  try {
    const { count, error } = await supabase
      .from('waitlist')
      .select('*', { count: 'exact', head: true });

    if (error) throw error;

    cachedCount = count ?? 0;
    cacheExpiresAt = Date.now() + CACHE_TTL_MS;

    return json({ total: cachedCount });
  } catch (err) {
    console.error('[waitlist-count] error:', err);
    return json({ error: 'Internal server error' }, 500);
  }
});
