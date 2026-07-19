// supabase/functions/likeness-purchase-card/index.ts
// Auth required. Mint a card from an active offering (sim mode only for now).
// Live mode: Stripe PaymentIntent must be confirmed via webhook before calling.
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
  const { offering_id } = body as { offering_id?: string };

  if (!offering_id) {
    return new Response(JSON.stringify({ error: 'Missing offering_id' }), {
      status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const { data: offering } = await supabase
    .from('likeness_offerings')
    .select('id, mode, character_name, creator_id')
    .eq('id', offering_id)
    .eq('status', 'active')
    .single();

  if (!offering) {
    return new Response(JSON.stringify({ error: 'Offering not found or not active' }), {
      status: 404, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  if (offering.mode === 'live') {
    return new Response(JSON.stringify({ error: 'Live mode payments must complete Stripe flow first' }), {
      status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // Call likeness_mint_card RPC (handles sim_usd debit + card INSERT + transfer)
  const { data: cardId, error: mintErr } = await supabase.rpc('likeness_mint_card', {
    p_offering_id: offering_id,
    p_buyer_user_id: user.id,
  });

  if (mintErr || !cardId) {
    console.error('[likeness-purchase-card] mint error:', mintErr?.message);
    return new Response(JSON.stringify({ error: mintErr?.message ?? 'Mint failed' }), {
      status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // Load card details for response + notifications
  const { data: card } = await supabase
    .from('likeness_cards')
    .select('card_number, rarity')
    .eq('id', cardId)
    .single();

  // Notify buyer
  await supabase.from('notifications').insert({
    user_id: user.id,
    type: 'card_minted',
    title: 'Card minted!',
    body: `You minted Card #${card?.card_number} — ${offering.character_name}!`,
    reference_id: cardId,
  }).then(() => null, () => null);

  // Notify creator
  await supabase.from('notifications').insert({
    user_id: offering.creator_id,
    type: 'card_sold',
    title: 'A card was purchased!',
    body: `Card #${card?.card_number} of your ${offering.character_name} offering was purchased.`,
    reference_id: cardId,
  }).then(() => null, () => null);

  return new Response(
    JSON.stringify({ card_id: cardId, card_number: card?.card_number, rarity: card?.rarity }),
    { status: 200, headers: { ...CORS, 'Content-Type': 'application/json' } },
  );
});
