// supabase/functions/chit-marketplace-buy/index.ts
// Auth required. Buy battle chits from a marketplace listing.
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
  const { listing_id, quantity = 1 } = body as {
    listing_id?: string;
    quantity?: number;
  };

  if (!listing_id || quantity < 1) {
    return new Response(JSON.stringify({ error: 'Missing or invalid fields' }), {
      status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // Load listing
  const { data: listing } = await supabase
    .from('chit_marketplace_listings')
    .select('id, seller_user_id, chit_definition_id, quantity_listed, price_per_unit_tokens, status')
    .eq('id', listing_id)
    .single();

  if (!listing || listing.status !== 'active') {
    return new Response(JSON.stringify({ error: 'Listing not found or not active' }), {
      status: 404, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  if (listing.seller_user_id === user.id) {
    return new Response(JSON.stringify({ error: 'Cannot buy your own listing' }), {
      status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  if (listing.quantity_listed < quantity) {
    return new Response(JSON.stringify({ error: 'Insufficient quantity in listing' }), {
      status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const totalCost = listing.price_per_unit_tokens * quantity;

  // Deduct buyer tokens
  const { data: buyerBal } = await supabase
    .from('token_balances')
    .select('available_tokens')
    .eq('user_id', user.id)
    .single();

  if (!buyerBal || buyerBal.available_tokens < totalCost) {
    return new Response(JSON.stringify({ error: 'Insufficient token balance' }), {
      status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const { error: deductErr } = await supabase
    .from('token_balances')
    .update({ available_tokens: buyerBal.available_tokens - totalCost })
    .eq('user_id', user.id);
  if (deductErr) throw deductErr;

  // Credit seller
  await supabase.rpc('increment_token_balance', {
    p_user_id: listing.seller_user_id,
    p_amount: totalCost,
  });

  // Add to buyer's inventory
  const { data: buyerInv } = await supabase
    .from('user_battle_chits')
    .select('id, quantity')
    .eq('user_id', user.id)
    .eq('chit_definition_id', listing.chit_definition_id)
    .maybeSingle();

  if (buyerInv) {
    await supabase
      .from('user_battle_chits')
      .update({ quantity: buyerInv.quantity + quantity })
      .eq('id', buyerInv.id);
  } else {
    await supabase.from('user_battle_chits').insert({
      user_id: user.id,
      chit_definition_id: listing.chit_definition_id,
      quantity,
      acquired_via: 'marketplace_purchase',
    });
  }

  // Update listing quantity / status
  const newQty = listing.quantity_listed - quantity;
  await supabase
    .from('chit_marketplace_listings')
    .update({ quantity_listed: newQty, status: newQty === 0 ? 'sold' : 'active' })
    .eq('id', listing_id);

  // Log transactions (Hard Rule #5)
  await supabase.from('token_transactions').insert([
    {
      user_id: user.id,
      type: 'chit_purchase',
      amount: totalCost,
      reference_id: listing_id,
      description: `Bought ${quantity} chit(s) from marketplace`,
    },
    {
      user_id: listing.seller_user_id,
      type: 'chit_sale',
      amount: totalCost,
      reference_id: listing_id,
      description: `Sold ${quantity} chit(s) on marketplace`,
    },
  ]);

  return new Response(JSON.stringify({ success: true, quantity_purchased: quantity }), {
    status: 200, headers: { ...CORS, 'Content-Type': 'application/json' },
  });
});
