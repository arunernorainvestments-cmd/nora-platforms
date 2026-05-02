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

// 10-char URL-safe base64 from 8 random bytes. Collision probability at 10k rows: ~4e-13.
function generateToken(): string {
  const bytes = crypto.getRandomValues(new Uint8Array(8));
  return btoa(String.fromCharCode(...bytes))
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replaceAll('=', '')
    .substring(0, 10);
}

const APP_URL = Deno.env.get('APP_URL') ?? 'https://noraplatforms.com';

// ── Rate limiting (in-memory, best-effort for cold starts) ───────────────────
// Post-launch: replace with persistent store (e.g. Supabase KV or Redis).
const rateLimitMap = new Map<string, { count: number; resetAt: number }>();
const RATE_LIMIT = 5;
const RATE_WINDOW_MS = 60 * 60 * 1000; // 1 hour

function isRateLimited(ip: string): boolean {
  const now = Date.now();
  const entry = rateLimitMap.get(ip);
  if (!entry || now > entry.resetAt) {
    rateLimitMap.set(ip, { count: 1, resetAt: now + RATE_WINDOW_MS });
    return false;
  }
  entry.count++;
  return entry.count > RATE_LIMIT;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: CORS_HEADERS });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  // Rate limit by IP (best-effort — in-memory per cold start)
  const ip = req.headers.get('x-forwarded-for')?.split(',')[0]?.trim() ?? 'unknown';
  if (isRateLimited(ip)) {
    return json({ error: 'Too many requests. Please try again later.' }, 429);
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    { auth: { persistSession: false } },
  );

  let body: { email?: string; referral_token?: string };
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Invalid request body' }, 400);
  }

  const email = (body.email ?? '').trim().toLowerCase();
  if (!/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email)) {
    return json({ error: 'Invalid email address' }, 400);
  }

  const inboundReferrerToken = body.referral_token?.trim() ?? null;

  try {
    // ── Check if email already exists ────────────────────────────────────────
    const { data: existing, error: lookupErr } = await supabase
      .from('waitlist')
      .select('email, referral_token, referral_count, created_at')
      .eq('email', email)
      .maybeSingle();

    if (lookupErr) throw lookupErr;

    if (existing) {
      // Already on the list — return existing position.
      const { data: pos, error: posErr } = await supabase
        .rpc('waitlist_position_by_email', { p_email: email });
      if (posErr) throw posErr;

      const row = Array.isArray(pos) ? pos[0] : pos;
      return json({
        user: {
          email: existing.email,
          referral_token: existing.referral_token,
          referral_count: existing.referral_count,
          created_at: existing.created_at,
        },
        queue_position: Number(row?.queue_position ?? 1),
        total_count: Number(row?.total_count ?? 1),
        referral_link: `${APP_URL}/w/${existing.referral_token}`,
        is_new_user: false,
      });
    }

    // ── New signup ────────────────────────────────────────────────────────────

    // Generate unique referral token (retry on collision — vanishingly rare)
    let newToken = '';
    for (let attempt = 0; attempt < 10; attempt++) {
      const candidate = generateToken();
      const { data: collision } = await supabase
        .from('waitlist')
        .select('referral_token')
        .eq('referral_token', candidate)
        .maybeSingle();
      if (!collision) { newToken = candidate; break; }
    }
    if (!newToken) throw new Error('Failed to generate unique referral token');

    // ── Resolve referrer ──────────────────────────────────────────────────────
    let referredBy: string | null = null;
    let referrerCurrentCount = 0;

    if (inboundReferrerToken) {
      const { data: referrer } = await supabase
        .from('waitlist')
        .select('email, referral_token, referral_count')
        .eq('referral_token', inboundReferrerToken)
        .maybeSingle();

      // Self-referral check: referrer must exist and be a different email
      if (referrer && referrer.email !== email) {
        referredBy = inboundReferrerToken;
        referrerCurrentCount = referrer.referral_count;
      }
      // Unknown token → referredBy stays null (silent fallback, don't error)
    }

    // ── Insert new row ────────────────────────────────────────────────────────
    const { data: inserted, error: insertErr } = await supabase
      .from('waitlist')
      .insert({
        email,
        referral_token: newToken,
        referred_by: referredBy,
        referral_count: 0,
        source: 'waitlist_signup_fn',
      })
      .select('email, referral_token, referral_count, created_at')
      .single();

    if (insertErr) throw insertErr;

    // ── Increment referrer count ──────────────────────────────────────────────
    if (referredBy) {
      await supabase
        .from('waitlist')
        .update({ referral_count: referrerCurrentCount + 1 })
        .eq('referral_token', referredBy);
    }

    // ── Compute queue position ────────────────────────────────────────────────
    const { data: pos, error: posErr } = await supabase
      .rpc('waitlist_position_by_email', { p_email: email });
    if (posErr) throw posErr;

    const row = Array.isArray(pos) ? pos[0] : pos;

    return json({
      user: {
        email: inserted.email,
        referral_token: inserted.referral_token,
        referral_count: inserted.referral_count,
        created_at: inserted.created_at,
      },
      queue_position: Number(row?.queue_position ?? 1),
      total_count: Number(row?.total_count ?? 1),
      referral_link: `${APP_URL}/w/${inserted.referral_token}`,
      is_new_user: true,
    });
  } catch (err) {
    console.error('[waitlist-signup] error:', err);
    return json({ error: 'Internal server error' }, 500);
  }
});
