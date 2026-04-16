// supabase/functions/oauth-initiate/index.ts
// Generates the platform OAuth authorization URL and returns it to the Flutter app.
// Flutter opens the URL with url_launcher; the user grants access in their browser.
// Deployed with --no-verify-jwt; auth is verified via supabase.auth.getUser() instead,
// because this project uses ES256 JWTs which are incompatible with the runtime's HS256 check.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': 'https://nora-platforms.vercel.app',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface InitiateRequest {
  platform: 'youtube' | 'twitch' | 'x';
  user_id: string;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { status: 200, headers: corsHeaders });
  }

  if (req.method !== 'POST') {
    return json({ error: 'Method not allowed' }, 405, corsHeaders);
  }

  // Verify the user JWT via Supabase Auth (handles ES256 asymmetric keys)
  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) {
    return json({ error: 'Unauthorized' }, 401, corsHeaders);
  }
  const token = authHeader.replace('Bearer ', '');
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_ANON_KEY') ?? '',
  );
  const { data: { user }, error: authError } = await supabase.auth.getUser(token);
  if (authError || !user) {
    return json({ error: 'Unauthorized', detail: authError?.message }, 401, corsHeaders);
  }

  let body: InitiateRequest;
  try {
    body = await req.json();
  } catch {
    return json({ error: 'Invalid JSON body' }, 400, corsHeaders);
  }

  const { platform, user_id } = body;
  if (!platform || !user_id) {
    return json({ error: 'Missing required fields: platform, user_id' }, 400, corsHeaders);
  }

  if (platform !== 'youtube' && platform !== 'twitch' && platform !== 'x') {
    return json({ error: `OAuth not configured for platform: ${platform}` }, 400, corsHeaders);
  }

  const stateSecret = Deno.env.get('OAUTH_STATE_SECRET') ?? '';
  const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
  const callbackUri = `${supabaseUrl}/functions/v1/oauth-callback`;

  // Build signed state token to prevent CSRF
  const statePayload = btoa(JSON.stringify({ user_id, platform, ts: Date.now() }));
  const sig = await signHmac(statePayload, stateSecret);
  const state = `${statePayload}.${sig}`;

  let authUrl: string;

  if (platform === 'youtube') {
    const clientId = Deno.env.get('YOUTUBE_CLIENT_ID') ?? '';
    const params = new URLSearchParams({
      client_id: clientId,
      redirect_uri: callbackUri,
      response_type: 'code',
      scope: 'https://www.googleapis.com/auth/youtube.readonly',
      state,
      access_type: 'offline',
      prompt: 'consent',
    });
    authUrl = `https://accounts.google.com/o/oauth2/auth?${params.toString()}`;
  } else if (platform === 'twitch') {
    const clientId = Deno.env.get('TWITCH_CLIENT_ID') ?? '';
    const params = new URLSearchParams({
      client_id: clientId,
      redirect_uri: callbackUri,
      response_type: 'code',
      scope: 'user:read:follows channel:read:stream_key',
      state,
      force_verify: 'true', // always show consent page; prevents silent re-auth redirect loop
    });
    authUrl = `https://id.twitch.tv/oauth2/authorize?${params.toString()}`;
  } else {
    // x — confidential client (Web App), no PKCE required
    const clientId = Deno.env.get('X_CLIENT_ID') ?? '';
    const params = new URLSearchParams({
      response_type: 'code',
      client_id: clientId,
      redirect_uri: callbackUri,
      scope: 'tweet.read users.read follows.read offline.access',
      state,
    });
    authUrl = `https://twitter.com/i/oauth2/authorize?${params.toString()}`;
  }

  return json({ auth_url: authUrl }, 200, corsHeaders);
});

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

async function signHmac(data: string, secret: string): Promise<string> {
  const key = await crypto.subtle.importKey(
    'raw',
    new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' },
    false,
    ['sign'],
  );
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(data));
  return Array.from(new Uint8Array(sig))
    .map((b) => b.toString(16).padStart(2, '0'))
    .join('');
}

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
