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

    if (event['type'] !== 'checkout.session.completed') {
      console.log('Ignoring event type:', event['type']);
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
