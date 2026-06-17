// supabase/functions/lkn-register-api-key/index.ts
//
// Registers a third-party API key for the licensing verification API.
// Public endpoint — no account required. Deploy with --no-verify-jwt.
//
// Free tier: 1,000 calls/day. Returns the full key ONCE (never retrievable again).
// The key is stored as-is in lkn_api_keys (RLS service-role-only). The caller must
// save it; we only ever expose api_key_preview afterwards.
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

// lkn_live_ + 40 url-safe random chars
function generateApiKey(): string {
  const chars = 'abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789';
  const bytes = new Uint8Array(40);
  crypto.getRandomValues(bytes);
  let out = '';
  for (const b of bytes) out += chars[b % chars.length];
  return 'lkn_live_' + out;
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  try {
    let body: {
      owner_name?: string;
      owner_email?: string;
      owner_website?: string;
      intended_use_description?: string;
    };
    try {
      body = await req.json();
    } catch {
      return json({ error: 'Invalid JSON body' }, 400);
    }

    const owner_name = (body.owner_name ?? '').trim();
    const owner_email = (body.owner_email ?? '').trim();
    if (!owner_name || !owner_email) {
      return json({ error: 'owner_name and owner_email are required' }, 400);
    }
    if (!/^[^@\s]+@[^@\s]+\.[^@\s]+$/.test(owner_email)) {
      return json({ error: 'owner_email is not a valid email' }, 400);
    }

    const service = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const apiKey = generateApiKey();
    const preview = apiKey.slice(0, 12) + '...';

    const { error } = await service.from('lkn_api_keys').insert({
      api_key: apiKey,
      api_key_preview: preview,
      owner_name,
      owner_email,
      owner_website: body.owner_website ?? null,
      intended_use_description: body.intended_use_description ?? null,
      tier: 'free',
      daily_call_limit: 1000,
    });
    if (error) {
      console.error('lkn-register-api-key insert error:', JSON.stringify(error));
      return json({ error: 'Could not register API key' }, 500);
    }

    // Return the full key exactly once.
    return json({
      api_key: apiKey,
      api_key_preview: preview,
      tier: 'free',
      daily_call_limit: 1000,
      docs_url: 'https://noraplatforms.com/license-api',
      note: 'Store this key now — it cannot be retrieved again.',
    }, 201);
  } catch (err) {
    console.error('lkn-register-api-key error:', err);
    return json({ error: 'Internal server error' }, 500);
  }
});
