// supabase/functions/disconnect-platform/index.ts
// Revokes the OAuth token with the platform and removes the connection from DB.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': 'https://nora-platforms.vercel.app',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { status: 200, headers: corsHeaders });
  }

  if (req.method !== 'POST') {
    return json({ error: 'Method not allowed' }, 405, corsHeaders);
  }

  // Verify user JWT
  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) {
    return json({ error: 'Unauthorized' }, 401, corsHeaders);
  }
  const userToken = authHeader.replace('Bearer ', '');

  // Parse body
  let platform: string;
  try {
    const body = await req.json();
    platform = body.platform;
  } catch {
    return json({ error: 'Invalid JSON body' }, 400, corsHeaders);
  }

  if (!platform) {
    return json({ error: 'Missing required field: platform' }, 400, corsHeaders);
  }

  if (!['youtube', 'twitch'].includes(platform)) {
    return json({ error: `Disconnect not supported for platform: ${platform}` }, 400, corsHeaders);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';

  // User-scoped client — respects RLS to identify which user is calling
  const userClient = createClient(supabaseUrl, Deno.env.get('SUPABASE_ANON_KEY') ?? '', {
    auth: { persistSession: false },
    global: { headers: { Authorization: `Bearer ${userToken}` } },
  });

  // Service-role client for writes
  const adminClient = createClient(
    supabaseUrl,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    { auth: { persistSession: false } },
  );

  // Get user id from token
  const { data: userData, error: userErr } = await userClient.auth.getUser();
  if (userErr || !userData.user) {
    return json({ error: 'Invalid token' }, 401, corsHeaders);
  }
  const userId = userData.user.id;

  // Fetch connection record
  const { data: conn, error: fetchErr } = await adminClient
    .from('platform_connections')
    .select('id, access_token, refresh_token')
    .eq('user_id', userId)
    .eq('platform', platform)
    .single();

  if (fetchErr || !conn) {
    return json({ error: 'Connection not found' }, 404, corsHeaders);
  }

  // Revoke token with platform (best-effort — don't fail if revoke fails)
  await revokeToken(platform, conn.access_token as string).catch((err) => {
    console.warn(`[disconnect-platform] Token revoke failed (non-fatal):`, err);
  });

  // Delete connection (cascades to platform_metrics)
  const { error: deleteErr } = await adminClient
    .from('platform_connections')
    .delete()
    .eq('id', conn.id);

  if (deleteErr) {
    console.error('[disconnect-platform] Delete failed:', deleteErr.message);
    return json({ error: 'Failed to delete connection' }, 500, corsHeaders);
  }

  return json({ success: true, platform }, 200, corsHeaders);
});

// ─────────────────────────────────────────────────────────────────────────────
// Platform token revocation
// ─────────────────────────────────────────────────────────────────────────────

async function revokeToken(platform: string, accessToken: string): Promise<void> {
  if (platform === 'youtube') {
    await fetch(
      `https://oauth2.googleapis.com/revoke?token=${encodeURIComponent(accessToken)}`,
      { method: 'POST' },
    );
  } else {
    // twitch
    await fetch('https://id.twitch.tv/oauth2/revoke', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: Deno.env.get('TWITCH_CLIENT_ID') ?? '',
        token: accessToken,
      }),
    });
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

function json(
  body: unknown,
  status: number,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...extraHeaders },
  });
}
