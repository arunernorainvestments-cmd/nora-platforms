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

  // ── One atomic RPC (mig 180) ────────────────────────────────────────────────
  // Was: read balance -> write (balance - cost), read listing qty -> write qty-n,
  // read inventory -> write qty+n, then log. Three separate read-then-write races
  // (lost debit, oversold listing, lost inventory), and none of it atomic with the
  // payment — a mid-flight failure could take tokens and deliver nothing.
  // chit_marketplace_buy_atomic locks the listing, debits with a single guarded
  // UPDATE, moves inventory, and logs both ledger rows in ONE transaction.
  const { data: result, error: buyError } = await supabase.rpc('chit_marketplace_buy_atomic', {
    p_buyer: user.id,
    p_listing: listing_id,
    p_quantity: quantity,
  });

  if (buyError) {
    const msg = buyError.message ?? '';
    const status =
      msg.includes('Insufficient token balance') ? 400 :
      msg.includes('Insufficient quantity')      ? 400 :
      msg.includes('Cannot buy your own')        ? 400 :
      msg.includes('not found or not active')    ? 404 : 500;
    return new Response(JSON.stringify({ error: msg || 'Purchase failed' }), {
      status, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  return new Response(JSON.stringify(result ?? { success: true, quantity_purchased: quantity }), {
    status: 200, headers: { ...CORS, 'Content-Type': 'application/json' },
  });
});
