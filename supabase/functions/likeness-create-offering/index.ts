// supabase/functions/likeness-create-offering/index.ts
// Auth required. Creator submits a new likeness card offering.
// Validates market maker eligibility and enforces one-active-offering-per-creator.
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
  const {
    character_name,
    character_image_url,
    archetype,
    total_pct_offered,
    card_print_run,
    price_per_card_usd_cents,
    mode = 'simulated',
  } = body as {
    character_name?: string;
    character_image_url?: string;
    archetype?: string;
    total_pct_offered?: number;
    card_print_run?: number;
    price_per_card_usd_cents?: number;
    mode?: string;
  };

  if (!character_name || !archetype || !total_pct_offered || !card_print_run || !price_per_card_usd_cents) {
    return new Response(JSON.stringify({ error: 'Missing required fields' }), {
      status: 400, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // Verify market maker eligibility
  const { data: profile } = await supabase
    .from('profiles')
    .select('is_market_maker, pending_opt_out')
    .eq('id', user.id)
    .single();

  if (!profile?.is_market_maker || profile?.pending_opt_out) {
    return new Response(JSON.stringify({ error: 'Not eligible to create offerings' }), {
      status: 403, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  // One active offering per creator
  const { data: existingOffering } = await supabase
    .from('likeness_offerings')
    .select('id')
    .eq('creator_id', user.id)
    .eq('status', 'active')
    .maybeSingle();

  if (existingOffering) {
    return new Response(JSON.stringify({ error: 'You already have an active offering' }), {
      status: 409, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  const pct_per_card = total_pct_offered / card_print_run;

  const { data: offering, error: insertErr } = await supabase
    .from('likeness_offerings')
    .insert({
      creator_id: user.id,
      character_name,
      character_image_url: character_image_url ?? null,
      archetype,
      total_pct_offered,
      card_print_run,
      pct_per_card,
      price_per_card_usd_cents,
      mode,
      status: 'active',
      listed_at: new Date().toISOString(),
    })
    .select('id')
    .single();

  if (insertErr || !offering) {
    console.error('[likeness-create-offering] insert error:', insertErr?.message);
    return new Response(JSON.stringify({ error: 'Failed to create offering' }), {
      status: 500, headers: { ...CORS, 'Content-Type': 'application/json' },
    });
  }

  return new Response(JSON.stringify({ offering_id: offering.id }), {
    status: 200, headers: { ...CORS, 'Content-Type': 'application/json' },
  });
});
