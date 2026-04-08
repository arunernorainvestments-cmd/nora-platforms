// supabase/functions/oauth-initiate/index.ts
// Generates the platform OAuth authorization URL and returns it to the Flutter app.
// Flutter opens the URL with url_launcher; the user grants access in their browser.

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface InitiateRequest {
  platform: 'youtube' | 'twitch';
  user_id: string;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders });
  }

  if (req.method !== 'POST') {
    return json({ error: 'Method not allowed' }, 405);
  }

  // Require a valid user JWT
  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) {
    return json({ error: 'Unauthorized' }, 401, corsHeaders);
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

  if (platform !== 'youtube' && platform !== 'twitch') {
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
  } else {
    // twitch
    const clientId = Deno.env.get('TWITCH_CLIENT_ID') ?? '';
    const params = new URLSearchParams({
      client_id: clientId,
      redirect_uri: callbackUri,
      response_type: 'code',
      scope: 'user:read:follows channel:read:stream_key',
      state,
    });
    authUrl = `https://id.twitch.tv/oauth2/authorize?${params.toString()}`;
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
