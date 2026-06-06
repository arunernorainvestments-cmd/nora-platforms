// supabase/functions/likeness-list-card/index.ts
// Auth required. List an owned card on the secondary marketplace.
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
  const { card_id, asking_price_usd_cents } = body as {
    card_id?: string;
    asking_price_usd_cents?: number;
  };

  if (!card_id || !asking_price_usd_cents || asking_price_usd_cents <= 0) {
    return new Response(JSON.stringify({ error: 'Missing or invalid fields' }), {
      status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // Verify ownership
  const { data: card } = await supabase
    .from('likeness_cards')
    .select('id, offering_id, creator_id, current_owner_id, is_active')
    .eq('id', card_id)
    .single();

  if (!card || card.current_owner_id !== user.id || !card.is_active) {
    return new Response(JSON.stringify({ error: 'Card not found or not owned by you' }), {
      status: 403, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // One active listing per card (enforced by EXCLUDE constraint, but pre-check for nicer error)
  const { data: existingListing } = await supabase
    .from('card_marketplace_listings')
    .select('id')
    .eq('card_id', card_id)
    .eq('status', 'active')
    .maybeSingle();

  if (existingListing) {
    return new Response(JSON.stringify({ error: 'Card already has an active listing' }), {
      status: 409, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const { data: offering } = await supabase
    .from('likeness_offerings')
    .select('mode')
    .eq('id', card.offering_id)
    .single();

  const { data: listing, error: insertErr } = await supabase
    .from('card_marketplace_listings')
    .insert({
      card_id,
      seller_user_id: user.id,
      offering_id: card.offering_id,
      creator_id: card.creator_id,
      asking_price_usd_cents,
      is_simulated: offering?.mode === 'simulated',
    })
    .select('id')
    .single();

  if (insertErr || !listing) {
    console.error('[likeness-list-card] insert error:', insertErr?.message);
    return new Response(JSON.stringify({ error: 'Failed to create listing' }), {
      status: 500, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  return new Response(JSON.stringify({ listing_id: listing.id }), {
    status: 200, headers: { ...CORS, 'Content-Type': 'application/json' },
  });
});
