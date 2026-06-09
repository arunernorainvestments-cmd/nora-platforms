// supabase/functions/kyc-create-session/index.ts
//
// Starts identity verification for the authenticated user.
//   • sim mode  (KYC_MODE != 'live'): auto-approves via kyc_simulate_approve and
//     returns { status: 'approved', mode: 'sim' }.
//   • live mode (KYC_MODE == 'live'): creates a Stripe Identity VerificationSession
//     (with metadata.user_id), writes a pending kyc_verifications row, and returns
//     { url, mode: 'live' } for the client to redirect to. The stripe-webhook handles
//     identity.verification_session.verified → kyc_verifications.identity_hash.
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': 'https://noraplatforms.com',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return json({ error: 'Missing authorization header' }, 401);

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) return json({ error: 'Unauthorized' }, 401);

    const serviceClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    // Already verified and unexpired → nothing to do.
    const { data: existing } = await serviceClient
      .from('kyc_verifications')
      .select('status, expires_at')
      .eq('user_id', user.id)
      .maybeSingle();
    if (
      existing?.status === 'approved' &&
      (!existing.expires_at || new Date(existing.expires_at as string) > new Date())
    ) {
      return json({ status: 'approved', mode: 'noop' }, 200);
    }

    const liveMode = (Deno.env.get('KYC_MODE') ?? 'sim') === 'live';

    if (!liveMode) {
      const { error } = await serviceClient.rpc('kyc_simulate_approve', { p_user_id: user.id });
      if (error) {
        console.error('kyc_simulate_approve error:', JSON.stringify(error));
        return json({ error: 'Simulated approval failed' }, 500);
      }
      return json({ status: 'approved', mode: 'sim' }, 200);
    }

    // ── Live: create a Stripe Identity VerificationSession ──
    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY');
    if (!stripeKey) {
      console.error('KYC_MODE=live but STRIPE_SECRET_KEY is not set');
      return json({ error: 'Verification not configured' }, 500);
    }
    const appUrl = Deno.env.get('APP_URL') ?? 'https://noraplatforms.com';

    const body = new URLSearchParams({
      'type': 'document',
      'metadata[user_id]': user.id,
      'return_url': `${appUrl}/verify-identity?kyc=done`,
    });
    const stripeRes = await fetch('https://api.stripe.com/v1/identity/verification_sessions', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${stripeKey}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: body.toString(),
    });
    const session = await stripeRes.json();
    if (!stripeRes.ok) {
      console.error('Stripe Identity error:', JSON.stringify(session));
      return json({ error: 'Failed to start verification' }, 500);
    }

    const nowIso = new Date().toISOString();
    const { error: upsertError } = await serviceClient
      .from('kyc_verifications')
      .upsert({
        user_id: user.id,
        status: 'pending',
        provider: 'stripe_identity',
        provider_session_id: session.id,
        submitted_at: nowIso,
      }, { onConflict: 'user_id' });
    if (upsertError) {
      console.error('kyc_verifications upsert error:', JSON.stringify(upsertError));
      // Session exists; the webhook still resolves it. Don't block the redirect.
    }

    return json({ url: session.url, mode: 'live' }, 200);
  } catch (err) {
    console.error('kyc-create-session error:', err);
    return json({ error: 'Internal server error' }, 500);
  }
});
