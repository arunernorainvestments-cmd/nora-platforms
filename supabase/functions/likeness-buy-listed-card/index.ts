// supabase/functions/likeness-buy-listed-card/index.ts
// Auth required. Purchase a card from the secondary marketplace (sim mode).
// Live mode: Stripe PaymentIntent must be confirmed via webhook first.
import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': 'https://noraplatforms.com',
  'Access-Control-Allow-Headers': 'content-type, authorization',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS });
  }

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), {
      status: 401, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  const anonClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } },
  );

  const { data: { user }, error: authErr } = await anonClient.auth.getUser();
  if (authErr || !user) {
    return new Response(JSON.stringify({ error: 'Invalid token' }), {
      status: 401, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const body = await req.json().catch(() => ({}));
  const { listing_id } = body as { listing_id?: string };

  if (!listing_id) {
    return new Response(JSON.stringify({ error: 'Missing listing_id' }), {
      status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const { data: listing } = await supabase
    .from('card_marketplace_listings')
    .select('id, is_simulated, seller_user_id, card_id')
    .eq('id', listing_id)
    .eq('status', 'active')
    .single();

  if (!listing) {
    return new Response(JSON.stringify({ error: 'Listing not found or already sold' }), {
      status: 404, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  if (!listing.is_simulated) {
    return new Response(JSON.stringify({ error: 'Live mode purchases require Stripe flow' }), {
      status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // RPC handles: sim balance debit/credit, transfer log, listing → sold, card owner update
  const { data: saleId, error: purchaseErr } = await supabase.rpc('card_marketplace_purchase', {
    p_listing_id: listing_id,
    p_buyer_user_id: user.id,
  });

  if (purchaseErr || !saleId) {
    console.error('[likeness-buy-listed-card] purchase error:', purchaseErr?.message);
    return new Response(JSON.stringify({ error: purchaseErr?.message ?? 'Purchase failed' }), {
      status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // Notifications
  await supabase.from('notifications').insert({
    user_id: user.id,
    type: 'card_purchased',
    title: 'Card purchased!',
    body: 'You acquired a card from the marketplace.',
    reference_id: listing.card_id,
  }).catch(() => null);

  await supabase.from('notifications').insert({
    user_id: listing.seller_user_id,
    type: 'card_sold',
    title: 'Your card sold!',
    body: 'Your marketplace listing was purchased.',
    reference_id: listing_id,
  }).catch(() => null);

  return new Response(JSON.stringify({ sale_id: saleId, card_id: listing.card_id }), {
    status: 200, headers: { ...CORS, 'Content-Type': 'application/json' },
  });
});
