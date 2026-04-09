// supabase/functions/stripe-webhook/index.ts
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { crypto } from 'https://deno.land/std@0.177.0/crypto/mod.ts';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'content-type, stripe-signature',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// Verify Stripe webhook signature using HMAC-SHA256
async function verifyStripeSignature(
  payload: string,
  sigHeader: string,
  secret: string,
): Promise<boolean> {
  try {
    const parts = sigHeader.split(',').reduce<Record<string, string>>((acc, part) => {
      const [k, v] = part.split('=');
      acc[k] = v;
      return acc;
    }, {});

    const timestamp = parts['t'];
    const signature = parts['v1'];
    if (!timestamp || !signature) return false;

    // Replay attack protection — reject events older than 5 minutes
    const eventAge = Math.floor(Date.now() / 1000) - parseInt(timestamp, 10);
    if (eventAge > 300) {
      console.error('Webhook timestamp too old:', eventAge, 'seconds');
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
    const signatureBytes = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(signedPayload));
    const computedSig = Array.from(new Uint8Array(signatureBytes))
      .map((b) => b.toString(16).padStart(2, '0'))
      .join('');

    return computedSig === signature;
  } catch (err) {
    console.error('Signature verification error:', err);
    return false;
  }
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  const payload = await req.text();
  const sigHeader = req.headers.get('stripe-signature') ?? '';
  const webhookSecret = Deno.env.get('STRIPE_WEBHOOK_SECRET')!;

  const isValid = await verifyStripeSignature(payload, sigHeader, webhookSecret);
  if (!isValid) {
    console.error('Invalid Stripe signature');
    return new Response(JSON.stringify({ error: 'Invalid signature' }), {
      status: 400,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  let event: Record<string, unknown>;
  try {
    event = JSON.parse(payload);
  } catch {
    return new Response(JSON.stringify({ error: 'Invalid JSON' }), {
      status: 400,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  // Only handle checkout.session.completed
  if (event['type'] !== 'checkout.session.completed') {
    return new Response(JSON.stringify({ received: true }), {
      status: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  const session = event['data'] as Record<string, unknown>;
  const sessionObj = session['object'] as Record<string, unknown>;
  const metadata = sessionObj['metadata'] as Record<string, string>;
  const stripeSessionId = sessionObj['id'] as string;
  const paymentIntentId = (sessionObj['payment_intent'] as string) ?? null;

  const userId = metadata['user_id'];
  const packageId = metadata['package_id'];
  const tokensGranted = parseInt(metadata['tokens_granted'], 10);

  if (!userId || !packageId || !tokensGranted) {
    console.error('Missing metadata in session:', metadata);
    return new Response(JSON.stringify({ error: 'Missing metadata' }), {
      status: 400,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  const serviceClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  // Idempotency guard — if already completed, skip processing entirely
  const { data: existingPurchase, error: lookupError } = await serviceClient
    .from('token_purchases')
    .select('status')
    .eq('stripe_session_id', stripeSessionId)
    .single();

  if (lookupError) {
    console.error('Failed to look up purchase:', lookupError);
    return new Response(JSON.stringify({ error: 'Purchase lookup failed' }), {
      status: 500,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  if (existingPurchase?.status === 'completed') {
    console.log('Already processed, skipping:', stripeSessionId);
    return new Response(JSON.stringify({ received: true }), {
      status: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  // Update purchase record to completed
  const { error: updateError } = await serviceClient
    .from('token_purchases')
    .update({
      status: 'completed',
      stripe_payment_intent_id: paymentIntentId,
      completed_at: new Date().toISOString(),
    })
    .eq('stripe_session_id', stripeSessionId);

  if (updateError) {
    console.error('Failed to update token_purchases:', updateError);
    // Continue — still credit tokens so user isn't left hanging
  }

  // Credit tokens atomically using a raw increment to avoid race conditions
  const { error: creditError } = await serviceClient.rpc('increment_token_balance', {
    p_user_id: userId,
    p_amount: tokensGranted,
  });

  if (creditError) {
    console.error('Failed to credit tokens:', creditError);
    return new Response(JSON.stringify({ error: 'Token credit failed' }), {
      status: 500,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  // Log immutable transaction record
  const { error: txError } = await serviceClient
    .from('token_transactions')
    .insert({
      user_id: userId,
      amount: tokensGranted,
      type: 'purchase',
      description: `Token purchase — ${packageId} package`,
      reference_id: stripeSessionId,
    });

  if (txError) {
    console.error('Failed to insert token_transaction:', txError);
    // Non-fatal — balance already credited
  }

  console.log(`Credited ${tokensGranted} tokens to user ${userId} for session ${stripeSessionId}`);

  return new Response(JSON.stringify({ received: true }), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
});
