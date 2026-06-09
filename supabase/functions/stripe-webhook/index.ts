// supabase/functions/stripe-webhook/index.ts
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'content-type, stripe-signature',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

async function verifyStripeSignature(
  payload: string,
  sigHeader: string,
  secret: string,
): Promise<boolean> {
  try {
    const parts: Record<string, string> = {};
    for (const part of sigHeader.split(',')) {
      const idx = part.indexOf('=');
      if (idx !== -1) {
        parts[part.slice(0, idx)] = part.slice(idx + 1);
      }
    }

    const timestamp = parts['t'];
    const signature = parts['v1'];

    if (!timestamp || !signature) {
      console.error('Missing t or v1 in stripe-signature header. Header was:', sigHeader);
      return false;
    }

    const eventAge = Math.floor(Date.now() / 1000) - parseInt(timestamp, 10);
    if (eventAge > 300) {
      console.error('Webhook too old:', eventAge, 'seconds');
      return false;
    }

    const signedPayload = `${timestamp}.${payload}`;
    const key = await crypto.subtle.importKey(
      'raw',
      new TextEncoder().encode(secret),
      { name: 'HMAC', hash: 'SHA-256' },
      false,
      ['sign'],
    );
    const signatureBytes = await crypto.subtle.sign(
      'HMAC',
      key,
      new TextEncoder().encode(signedPayload),
    );
    const computedSig = Array.from(new Uint8Array(signatureBytes))
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('');

    const match = computedSig === signature;
    if (!match) {
      console.error('Signature mismatch. Computed:', computedSig, 'Expected:', signature);
    }
    return match;
  } catch (err) {
    console.error('Signature verification threw:', err);
    return false;
  }
}

async function sha256Hex(input: string): Promise<string> {
  const bytes = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(input));
  return Array.from(new Uint8Array(bytes)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

function jsonResponse(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}

// Stripe Identity → kyc_verifications.identity_hash (the sybil anchor, migration 102).
// On a verified session we derive a stable identity hash (normalized name + DOB —
// Stripe Identity does not expose raw document numbers) and write it to the user's KYC
// row. The partial-UNIQUE index on identity_hash enforces one verified human → one
// staking account: a second account verifying the SAME identity hits a 23505 here and
// is marked rejected. Raw identity documents are never stored.
async function handleIdentityVerified(event: Record<string, unknown>): Promise<Response> {
  const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  if (!supabaseUrl || !serviceRoleKey) {
    console.error('identity webhook: missing SUPABASE_URL / SERVICE_ROLE_KEY');
    return jsonResponse({ error: 'Server misconfigured' }, 500);
  }
  const sb = createClient(supabaseUrl, serviceRoleKey);

  const session = (event['data'] as Record<string, unknown>)['object'] as Record<string, unknown>;
  const sessionId = session['id'] as string;
  const metadata = (session['metadata'] ?? {}) as Record<string, string>;
  const userId = metadata['user_id'];
  if (!userId) {
    console.error('identity webhook: no user_id in session metadata', sessionId);
    return jsonResponse({ error: 'Missing user_id metadata' }, 400);
  }

  // verified_outputs may be absent on the event payload — retrieve it with expand.
  let outputs = (session['verified_outputs'] ?? null) as Record<string, unknown> | null;
  if (!outputs) {
    const secret = Deno.env.get('STRIPE_SECRET_KEY') ?? '';
    if (secret) {
      const r = await fetch(
        `https://api.stripe.com/v1/identity/verification_sessions/${sessionId}?expand[]=verified_outputs`,
        { headers: { Authorization: `Bearer ${secret}` } },
      );
      if (r.ok) {
        outputs = ((await r.json())['verified_outputs'] ?? null) as Record<string, unknown> | null;
      } else {
        console.error('identity webhook: session retrieve failed', await r.text());
      }
    }
  }
  if (!outputs) {
    console.error('identity webhook: no verified_outputs for', sessionId);
    return jsonResponse({ received: true, note: 'no verified_outputs' }, 200);
  }

  const first = String(outputs['first_name'] ?? '').trim().toLowerCase();
  const last = String(outputs['last_name'] ?? '').trim().toLowerCase();
  const dobObj = (outputs['dob'] ?? {}) as Record<string, number>;
  const dob = dobObj['year']
    ? `${dobObj['year']}-${String(dobObj['month']).padStart(2, '0')}-${String(dobObj['day']).padStart(2, '0')}`
    : '';
  if (!first || !last || !dob) {
    console.error('identity webhook: incomplete identity fields', sessionId);
    return jsonResponse({ received: true, note: 'incomplete identity' }, 200);
  }

  const identityHash = await sha256Hex(`${first}|${last}|${dob}`);
  const nowIso = new Date().toISOString();
  const expiresIso = new Date(Date.now() + 365 * 24 * 60 * 60 * 1000).toISOString();

  const { error } = await sb.from('kyc_verifications').upsert({
    user_id: userId,
    status: 'approved',
    provider: 'stripe_identity',
    provider_session_id: sessionId,
    identity_hash: identityHash,
    verified_legal_name: `${outputs['first_name'] ?? ''} ${outputs['last_name'] ?? ''}`.trim(),
    date_of_birth: dob,
    verified_at: nowIso,
    expires_at: expiresIso,
    submitted_at: nowIso,
  }, { onConflict: 'user_id' });

  if (error) {
    // 23505 = identity_hash already approved on another account → sybil; reject this one.
    if ((error as { code?: string }).code === '23505') {
      await sb.from('kyc_verifications').upsert({
        user_id: userId,
        status: 'rejected',
        provider: 'stripe_identity',
        provider_session_id: sessionId,
        rejected_reason: 'This identity is already verified on another account',
      }, { onConflict: 'user_id' });
      console.warn('identity webhook: duplicate identity rejected for user', userId);
      return jsonResponse({ received: true, rejected: 'duplicate_identity' }, 200);
    }
    console.error('identity webhook: kyc upsert error', JSON.stringify(error));
    return jsonResponse({ error: 'KYC update failed' }, 500);
  }

  console.log('identity webhook: approved KYC for user', userId);
  return jsonResponse({ received: true, approved: true }, 200);
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  try {
    const payload = await req.text();
    const sigHeader = req.headers.get('stripe-signature') ?? '';
    const webhookSecret = Deno.env.get('STRIPE_WEBHOOK_SECRET') ?? '';

    if (!webhookSecret) {
      console.error('STRIPE_WEBHOOK_SECRET is not set');
      return new Response(JSON.stringify({ error: 'Webhook secret not configured' }), {
        status: 500,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    const isValid = await verifyStripeSignature(payload, sigHeader, webhookSecret);
    if (!isValid) {
      return new Response(JSON.stringify({ error: 'Invalid signature' }), {
        status: 400,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    let event: Record<string, unknown>;
    try {
      event = JSON.parse(payload);
    } catch {
      console.error('Failed to parse JSON payload');
      return new Response(JSON.stringify({ error: 'Invalid JSON' }), {
        status: 400,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    const eventType = event['type'] as string;

    // Stripe Identity verification → KYC identity_hash (sybil anchor, migration 102).
    if (eventType === 'identity.verification_session.verified') {
      return await handleIdentityVerified(event);
    }

    if (eventType !== 'checkout.session.completed') {
      console.log('Ignoring event type:', eventType);
      return new Response(JSON.stringify({ received: true }), {
        status: 200,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    const sessionObj = (event['data'] as Record<string, unknown>)['object'] as Record<string, unknown>;
    const metadata = (sessionObj['metadata'] ?? {}) as Record<string, string>;
    const stripeSessionId = sessionObj['id'] as string;
    const paymentIntentId = (sessionObj['payment_intent'] as string) ?? null;

    const userId = metadata['user_id'];
    const packageId = metadata['package_id'];
    const tokensGranted = parseInt(metadata['tokens_granted'] ?? '0', 10);

    console.log('Processing session:', stripeSessionId, 'user:', userId, 'tokens:', tokensGranted);

    if (!userId || !packageId || !tokensGranted) {
      console.error('Missing metadata — userId:', userId, 'packageId:', packageId, 'tokens:', tokensGranted);
      return new Response(JSON.stringify({ error: 'Missing metadata' }), {
        status: 400,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
    const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

    if (!supabaseUrl || !serviceRoleKey) {
      console.error('Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY');
      return new Response(JSON.stringify({ error: 'Server misconfigured' }), {
        status: 500,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    const serviceClient = createClient(supabaseUrl, serviceRoleKey);

    // Idempotency check — if already completed, do not credit again
    const { data: existing } = await serviceClient
      .from('token_purchases')
      .select('status')
      .eq('stripe_session_id', stripeSessionId)
      .single();

    if (existing?.status === 'completed') {
      console.log('Already processed session:', stripeSessionId, '— skipping');
      return new Response(JSON.stringify({ received: true }), {
        status: 200,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    const { error: updateError } = await serviceClient
      .from('token_purchases')
      .update({
        status: 'completed',
        stripe_payment_intent_id: paymentIntentId,
        completed_at: new Date().toISOString(),
      })
      .eq('stripe_session_id', stripeSessionId);

    if (updateError) {
      console.error('token_purchases update error:', JSON.stringify(updateError));
    }

    const { error: creditError } = await serviceClient.rpc('increment_token_balance', {
      p_user_id: userId,
      p_amount: tokensGranted,
    });

    if (creditError) {
      console.error('increment_token_balance error:', JSON.stringify(creditError));
      return new Response(JSON.stringify({ error: 'Token credit failed' }), {
        status: 500,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    const { error: txError } = await serviceClient
      .from('token_transactions')
      .insert({
        user_id: userId,
        amount: tokensGranted,
        type: 'purchased',
        description: `Token purchase — ${packageId} package`,
        reference_id: stripeSessionId,
      });

    if (txError) {
      console.error('token_transactions insert error:', JSON.stringify(txError));
    }

    console.log('Success: credited', tokensGranted, 'tokens to user', userId);

    return new Response(JSON.stringify({ received: true }), {
      status: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });

  } catch (err) {
    console.error('Unhandled error in stripe-webhook:', err);
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }
});
