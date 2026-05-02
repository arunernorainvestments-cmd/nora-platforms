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

const APP_URL = Deno.env.get('APP_URL') ?? 'https://noraplatforms.com';

// Simple in-memory response cache (60s TTL).
// Each entry: { body: string; expiresAt: number }
const cache = new Map<string, { body: string; expiresAt: number }>();
const CACHE_TTL_MS = 60_000;

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== 'POST' && req.method !== 'GET') {
    return json({ error: 'Method not allowed' }, 405);
  }

  // Accept token from either: POST body { token } or GET query param ?token=
  let token: string | null = null;

  if (req.method === 'POST') {
    try {
      const body = await req.json() as { token?: string };
      token = body.token?.trim() ?? null;
    } catch {
      return json({ error: 'Invalid request body' }, 400);
    }
  } else {
    const url = new URL(req.url);
    token = url.searchParams.get('token');
  }

  if (!token || token.length < 6 || token.length > 20) {
    return json({ error: 'Invalid token format' }, 400);
  }

  // Check cache
  const cached = cache.get(token);
  if (cached && Date.now() < cached.expiresAt) {
    return new Response(cached.body, {
      status: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    { auth: { persistSession: false } },
  );

  try {
    const { data, error } = await supabase
      .rpc('waitlist_position_by_token', { p_token: token });

    if (error) throw error;

    const rows = Array.isArray(data) ? data : [];
    if (rows.length === 0) {
      return json({ error: 'Token not found' }, 404);
    }

    const row = rows[0];
    const responseBody = JSON.stringify({
      user: {
        email: row.email,
        referral_token: row.referral_token,
        referral_count: Number(row.referral_count),
        created_at: row.created_at,
      },
      queue_position: Number(row.queue_position),
      total_count: Number(row.total_count),
      referral_link: `${APP_URL}/w/${row.referral_token}`,
    });

    cache.set(token, { body: responseBody, expiresAt: Date.now() + CACHE_TTL_MS });

    return new Response(responseBody, {
      status: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  } catch (err) {
    console.error('[waitlist-position] error:', err);
    return json({ error: 'Internal server error' }, 500);
  }
});
