// supabase/functions/create-checkout-session/index.ts
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': 'https://nora-platforms.vercel.app',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

const PACKAGES: Record<string, { tokens: number; amountCents: number; label: string }> = {
  starter: { tokens: 120,   amountCents: 99,   label: 'Starter — 120 Tokens' },
  popular: { tokens: 650,   amountCents: 499,  label: 'Popular — 650 Tokens' },
  pro:     { tokens: 1650,  amountCents: 999,  label: 'Pro — 1,650 Tokens' },
  elite:   { tokens: 3500,  amountCents: 1999, label: 'Elite — 3,500 Tokens' },
};

serve(async (req: Request) => {
  // Handle CORS preflight
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  try {
    // Verify auth
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) {
      return new Response(JSON.stringify({ error: 'Missing authorization header' }), {
        status: 401,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } },
    );

    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) {
      return new Response(JSON.stringify({ error: 'Unauthorized' }), {
        status: 401,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    const { package_id } = await req.json();
    const pkg = PACKAGES[package_id];
    if (!pkg) {
      return new Response(JSON.stringify({ error: 'Invalid package_id' }), {
        status: 400,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    const stripeKey = Deno.env.get('STRIPE_SECRET_KEY')!;
    const appUrl = Deno.env.get('APP_URL') ?? 'https://nora-platforms.vercel.app';

    // Create Stripe Checkout session
    const stripeBody = new URLSearchParams({
      'payment_method_types[]': 'card',
      'line_items[0][price_data][currency]': 'usd',
      'line_items[0][price_data][product_data][name]': pkg.label,
      'line_items[0][price_data][product_data][description]':
        'N.O.R.A. Platforms tokens — for promotional use only, no cash value',
      'line_items[0][price_data][unit_amount]': String(pkg.amountCents),
      'line_items[0][quantity]': '1',
      'mode': 'payment',
      'success_url': `${appUrl}/wallet?purchase=success`,
      'cancel_url': `${appUrl}/wallet?purchase=cancelled`,
      'metadata[user_id]': user.id,
      'metadata[package_id]': package_id,
      'metadata[tokens_granted]': String(pkg.tokens),
    });

    const stripeRes = await fetch('https://api.stripe.com/v1/checkout/sessions', {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${stripeKey}`,
        'Content-Type': 'application/x-www-form-urlencoded',
      },
      body: stripeBody.toString(),
    });

    const session = await stripeRes.json();
    if (!stripeRes.ok) {
      console.error('Stripe error:', session);
      return new Response(JSON.stringify({ error: 'Failed to create checkout session' }), {
        status: 500,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    // Insert pending purchase row using service role
    const serviceClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    const { error: insertError } = await serviceClient
      .from('token_purchases')
      .insert({
        user_id: user.id,
        stripe_session_id: session.id,
        package_id,
        tokens_granted: pkg.tokens,
        amount_paid_cents: pkg.amountCents,
        currency: 'usd',
        status: 'pending',
      });

    if (insertError) {
      console.error('DB insert error:', insertError);
      // Don't block — session was created, webhook will still fire
    }

    return new Response(JSON.stringify({ session_url: session.url }), {
      status: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  } catch (err) {
    console.error('Unexpected error:', err);
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }
});
