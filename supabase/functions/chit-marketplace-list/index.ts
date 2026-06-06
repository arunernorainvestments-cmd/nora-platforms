// supabase/functions/chit-marketplace-list/index.ts
// Auth required. List owned battle chits for sale (uncommon+ only).
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
  const { chit_definition_id, quantity, price_per_unit_tokens } = body as {
    chit_definition_id?: string;
    quantity?: number;
    price_per_unit_tokens?: number;
  };

  if (!chit_definition_id || !quantity || quantity < 1 || !price_per_unit_tokens || price_per_unit_tokens < 1) {
    return new Response(JSON.stringify({ error: 'Missing or invalid fields' }), {
      status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // Verify chit is marketplace-eligible
  const { data: chitDef } = await supabase
    .from('battle_chit_definitions')
    .select('id, can_buy_in_marketplace, is_active')
    .eq('id', chit_definition_id)
    .single();

  if (!chitDef || !chitDef.is_active || !chitDef.can_buy_in_marketplace) {
    return new Response(JSON.stringify({ error: 'This chit cannot be listed on the marketplace' }), {
      status: 403, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // Verify user has enough in inventory
  const { data: inv } = await supabase
    .from('user_battle_chits')
    .select('quantity')
    .eq('user_id', user.id)
    .eq('chit_definition_id', chit_definition_id)
    .single();

  if (!inv || inv.quantity < quantity) {
    return new Response(JSON.stringify({ error: 'Insufficient chit inventory' }), {
      status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // Reserve quantity (decrement — reversed on cancel)
  const { error: decrErr } = await supabase
    .from('user_battle_chits')
    .update({ quantity: inv.quantity - quantity })
    .eq('user_id', user.id)
    .eq('chit_definition_id', chit_definition_id);

  if (decrErr) {
    return new Response(JSON.stringify({ error: 'Failed to reserve inventory' }), {
      status: 500, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const { data: listing, error: insertErr } = await supabase
    .from('chit_marketplace_listings')
    .insert({
      seller_user_id: user.id,
      chit_definition_id,
      quantity_listed: quantity,
      price_per_unit_tokens,
    })
    .select('id')
    .single();

  if (insertErr || !listing) {
    // Rollback reservation
    await supabase
      .from('user_battle_chits')
      .update({ quantity: inv.quantity })
      .eq('user_id', user.id)
      .eq('chit_definition_id', chit_definition_id);

    return new Response(JSON.stringify({ error: 'Failed to create listing' }), {
      status: 500, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  return new Response(JSON.stringify({ listing_id: listing.id }), {
    status: 200, headers: { ...CORS, 'Content-Type': 'application/json' },
  });
});
