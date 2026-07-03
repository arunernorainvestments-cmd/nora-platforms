// supabase/functions/oauth-callback/index.ts
// Handles the OAuth redirect from YouTube, Twitch, and X. Exchanges the auth code for
// tokens, stores them in platform_connections, triggers an initial metric sync,
// then redirects the user back to the app.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// Guard against double-invocation consuming a single-use auth code
const processedCodes = new Set<string>();

const corsHeaders = {
  'Access-Control-Allow-Origin': 'https://noraplatforms.com',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { status: 200, headers: corsHeaders });
  }

  if (req.method !== 'GET') {
    return new Response('Method not allowed', { status: 405, headers: corsHeaders });
  }

  const url = new URL(req.url);
  const code = url.searchParams.get('code');
  const state = url.searchParams.get('state');
  const error = url.searchParams.get('error');

  const appUrl = Deno.env.get('APP_URL') ?? '';

  // ── Handle OAuth denial ──────────────────────────────────────────────────
  if (error) {
    console.error('[oauth-callback] OAuth denied:', error);
    return Response.redirect(`${appUrl}/profile?error=oauth_denied`, 302);
  }

  if (!code || !state) {
    return Response.redirect(`${appUrl}/profile?error=missing_params`, 302);
  }

  // Guard against double-invocation (codes are single-use)
  if (processedCodes.has(code)) {
    console.warn('[oauth-callback] Duplicate request for code, ignoring');
    return Response.redirect(`${appUrl}/profile?error=duplicate_request`, 302);
  }
  processedCodes.add(code);

  // ── Verify CSRF state ────────────────────────────────────────────────────
  const stateSecret = Deno.env.get('OAUTH_STATE_SECRET') ?? '';
  const stateData = await verifyState(state, stateSecret);
  if (!stateData) {
    console.error('[oauth-callback] Invalid or expired state');
    return Response.redirect(`${appUrl}/profile?error=invalid_state`, 302);
  }

  const { user_id, platform } = stateData;
  const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
  const callbackUri = `${supabaseUrl}/functions/v1/oauth-callback`;

  // ── Exchange auth code for tokens ────────────────────────────────────────
  let tokens: TokenResponse;
  try {
    tokens = await exchangeCode(platform, code, callbackUri);
  } catch (err) {
    console.error('[oauth-callback] Token exchange failed:', err);
    return Response.redirect(`${appUrl}/profile?error=token_exchange_failed`, 302);
  }

  // ── Fetch platform user info ─────────────────────────────────────────────
  let platformUserId: string;
  let platformUsername: string;
  try {
    const info = await fetchPlatformUser(platform, tokens.access_token);
    platformUserId = info.id;
    platformUsername = info.username;
  } catch (err) {
    console.error('[oauth-callback] Platform user fetch failed:', err);
    return Response.redirect(`${appUrl}/profile?error=user_fetch_failed`, 302);
  }

  // ── Store connection in DB ───────────────────────────────────────────────
  const supabase = createClient(
    supabaseUrl,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    { auth: { persistSession: false } },
  );

  const expiresAt = tokens.expires_in
    ? new Date(Date.now() + tokens.expires_in * 1000).toISOString()
    : null;

  const { error: upsertErr } = await supabase
    .from('platform_connections')
    .upsert(
      {
        user_id,
        platform,
        platform_user_id: platformUserId,
        platform_username: platformUsername,
        access_token: tokens.access_token,
        refresh_token: tokens.refresh_token ?? null,
        token_expires_at: expiresAt,
        scopes: Array.isArray(tokens.scope)
          ? tokens.scope
          : (tokens.scope ?? '').split(/[ ,]+/).filter(Boolean),
        connected_at: new Date().toISOString(),
        is_active: true,
      },
      { onConflict: 'user_id,platform' },
    );

  if (upsertErr) {
    console.error('[oauth-callback] DB upsert failed:', upsertErr.message);
    return Response.redirect(`${appUrl}/profile?error=db_error`, 302);
  }

  // ── Trigger initial metric sync for this user (best-effort) ──────────────
  try {
    const syncUrl = `${supabaseUrl}/functions/v1/sync-platform-metrics`;
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    await fetch(syncUrl, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${serviceKey}`,
      },
      body: JSON.stringify({ user_id }),
    });
  } catch (err) {
    // Non-fatal — metrics will be picked up by the next cron run
    console.warn('[oauth-callback] Initial sync failed (non-fatal):', err);
  }

  // ── Redirect back to app ─────────────────────────────────────────────────
  return Response.redirect(`${appUrl}/profile?connected=${platform}`, 302);
});

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

interface TokenResponse {
  access_token: string;
  refresh_token?: string;
  expires_in?: number;
  scope?: string | string[];
}

interface PlatformUser {
  id: string;
  username: string;
}

// ─────────────────────────────────────────────────────────────────────────────
// Platform token exchange
// ─────────────────────────────────────────────────────────────────────────────

async function exchangeCode(
  platform: string,
  code: string,
  redirectUri: string,
): Promise<TokenResponse> {
  if (platform === 'youtube') {
    const res = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        code,
        client_id: Deno.env.get('YOUTUBE_CLIENT_ID') ?? '',
        client_secret: Deno.env.get('YOUTUBE_CLIENT_SECRET') ?? '',
        redirect_uri: redirectUri,
        grant_type: 'authorization_code',
      }),
    });
    if (!res.ok) throw new Error(`YouTube token exchange ${res.status}: ${await res.text()}`);
    return res.json();
  } else if (platform === 'twitch') {
    const res = await fetch('https://id.twitch.tv/oauth2/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        code,
        client_id: Deno.env.get('TWITCH_CLIENT_ID') ?? '',
        client_secret: Deno.env.get('TWITCH_CLIENT_SECRET') ?? '',
        redirect_uri: redirectUri,
        grant_type: 'authorization_code',
      }),
    });
    if (!res.ok) throw new Error(`Twitch token exchange ${res.status}: ${await res.text()}`);
    return res.json();
  } else if (platform === 'x') {
    // x — confidential client uses HTTP Basic auth
    const clientId = Deno.env.get('X_CLIENT_ID') ?? '';
    const clientSecret = Deno.env.get('X_CLIENT_SECRET') ?? '';
    const credentials = btoa(`${clientId}:${clientSecret}`);
    const res = await fetch('https://api.twitter.com/2/oauth2/token', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        Authorization: `Basic ${credentials}`,
      },
      body: new URLSearchParams({
        code,
        grant_type: 'authorization_code',
        redirect_uri: redirectUri,
        client_id: clientId,
      }),
    });
    if (!res.ok) throw new Error(`X token exchange ${res.status}: ${await res.text()}`);
    return res.json();
  } else if (platform === 'tiktok') {
    const res = await fetch('https://open.tiktokapis.com/v2/oauth/token/', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        code,
        client_key: Deno.env.get('TIKTOK_CLIENT_KEY') ?? '',
        client_secret: Deno.env.get('TIKTOK_CLIENT_SECRET') ?? '',
        redirect_uri: redirectUri,
        grant_type: 'authorization_code',
      }),
    });
    if (!res.ok) throw new Error(`TikTok token exchange ${res.status}: ${await res.text()}`);
    const data = await res.json();
    if (data.error) throw new Error(`TikTok token exchange error: ${data.error}`);
    return data;
  } else if (platform === 'instagram') {
    // Instagram API with Instagram Login: short-lived exchange, then upgrade to a
    // long-lived (~60d) token so minting doesn't force hourly re-links.
    const clientId = Deno.env.get('INSTAGRAM_CLIENT_ID') ?? '';
    const clientSecret = Deno.env.get('INSTAGRAM_CLIENT_SECRET') ?? '';
    const shortRes = await fetch('https://api.instagram.com/oauth/access_token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        code,
        client_id: clientId,
        client_secret: clientSecret,
        redirect_uri: redirectUri,
        grant_type: 'authorization_code',
      }),
    });
    if (!shortRes.ok) throw new Error(`Instagram token exchange ${shortRes.status}: ${await shortRes.text()}`);
    const short = await shortRes.json();
    const longRes = await fetch(
      'https://graph.instagram.com/access_token?grant_type=ig_exchange_token' +
      `&client_secret=${encodeURIComponent(clientSecret)}` +
      `&access_token=${encodeURIComponent(short.access_token)}`,
    );
    if (!longRes.ok) {
      // Long-lived upgrade failed — the short-lived token still works for ~1h.
      console.warn('[oauth-callback] Instagram long-lived exchange failed:', longRes.status);
      await longRes.body?.cancel();
      return { access_token: short.access_token, expires_in: 3600 };
    }
    return longRes.json();
  } else {
    // spotify — Basic auth with client_id:client_secret
    const clientId = Deno.env.get('SPOTIFY_CLIENT_ID') ?? '';
    const clientSecret = Deno.env.get('SPOTIFY_CLIENT_SECRET') ?? '';
    const credentials = btoa(`${clientId}:${clientSecret}`);
    const res = await fetch('https://accounts.spotify.com/api/token', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/x-www-form-urlencoded',
        Authorization: `Basic ${credentials}`,
      },
      body: new URLSearchParams({
        code,
        grant_type: 'authorization_code',
        redirect_uri: redirectUri,
      }),
    });
    if (!res.ok) throw new Error(`Spotify token exchange ${res.status}: ${await res.text()}`);
    return res.json();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Platform user info
// ─────────────────────────────────────────────────────────────────────────────

async function fetchPlatformUser(
  platform: string,
  accessToken: string,
): Promise<PlatformUser> {
  if (platform === 'youtube') {
    const res = await fetch(
      'https://www.googleapis.com/youtube/v3/channels?part=snippet&mine=true',
      { headers: { Authorization: `Bearer ${accessToken}` } },
    );
    if (!res.ok) throw new Error(`YouTube user fetch ${res.status}`);
    const data = await res.json();
    const channel = data.items?.[0];
    if (!channel) throw new Error('No YouTube channel found');
    return {
      id: channel.id as string,
      username: (channel.snippet?.title ?? channel.id) as string,
    };
  } else if (platform === 'twitch') {
    const clientId = Deno.env.get('TWITCH_CLIENT_ID') ?? '';
    const res = await fetch('https://api.twitch.tv/helix/users', {
      headers: {
        Authorization: `Bearer ${accessToken}`,
        'Client-Id': clientId,
      },
    });
    if (!res.ok) throw new Error(`Twitch user fetch ${res.status}`);
    const data = await res.json();
    const user = data.data?.[0];
    if (!user) throw new Error('No Twitch user found');
    return { id: user.id as string, username: user.login as string };
  } else if (platform === 'x') {
    const res = await fetch('https://api.twitter.com/2/users/me', {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    if (!res.ok) throw new Error(`X user fetch ${res.status}`);
    const data = await res.json();
    const user = data.data;
    if (!user) throw new Error('No X user found');
    return { id: user.id as string, username: user.username as string };
  } else if (platform === 'tiktok') {
    const res = await fetch(
      'https://open.tiktokapis.com/v2/user/info/?fields=open_id,union_id,display_name,username',
      { headers: { Authorization: `Bearer ${accessToken}` } },
    );
    if (!res.ok) throw new Error(`TikTok user fetch ${res.status}`);
    const data = await res.json();
    const u = data.data?.user;
    if (!u?.open_id) throw new Error('No TikTok user found');
    return { id: u.open_id as string, username: (u.username ?? u.display_name ?? u.open_id) as string };
  } else if (platform === 'instagram') {
    const res = await fetch(
      `https://graph.instagram.com/v23.0/me?fields=user_id,username&access_token=${encodeURIComponent(accessToken)}`,
    );
    if (!res.ok) throw new Error(`Instagram user fetch ${res.status}`);
    const data = await res.json();
    const id = data.user_id ?? data.id;
    if (!id) throw new Error('No Instagram user found');
    return { id: String(id), username: (data.username ?? String(id)) as string };
  } else {
    // spotify
    const res = await fetch('https://api.spotify.com/v1/me', {
      headers: { Authorization: `Bearer ${accessToken}` },
    });
    if (!res.ok) throw new Error(`Spotify user fetch ${res.status}`);
    const data = await res.json();
    if (!data.id) throw new Error('No Spotify user found');
    return {
      id: data.id as string,
      username: (data.display_name ?? data.id) as string,
    };
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// State verification (CSRF protection)
// ─────────────────────────────────────────────────────────────────────────────

async function verifyState(
  state: string,
  secret: string,
): Promise<{ user_id: string; platform: string } | null> {
  const parts = state.split('.');
  if (parts.length !== 2) return null;
  const [payloadB64, sig] = parts;

  const expectedSig = await signHmac(payloadB64, secret);
  if (sig !== expectedSig) return null;

  try {
    const payload = JSON.parse(atob(payloadB64)) as {
      user_id: string;
      platform: string;
      ts: number;
    };
    // Reject state tokens older than 1 hour
    if (Date.now() - payload.ts > 60 * 60 * 1000) return null;
    if (!payload.user_id || !payload.platform) return null;
    return { user_id: payload.user_id, platform: payload.platform };
  } catch {
    return null;
  }
}

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
