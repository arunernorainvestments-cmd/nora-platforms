// ubi-submit-request: Authenticated endpoint to submit an emergency fund request.
// Validates cooldown, pool cap, and pool availability before creating the request.
// Triggers ubi-ai-evaluate (pass 1) immediately after creation.

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401, headers: CORS });
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  );
  const userClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } }
  );

  const { data: { user } } = await userClient.auth.getUser();
  if (!user) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), { status: 401, headers: CORS });
  }

  let body: {
    amount_usd_cents: number;
    emergency_category: string;
    request_narrative: string;
  };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: 'Invalid JSON body' }), { status: 400, headers: CORS });
  }

  const { amount_usd_cents, emergency_category, request_narrative } = body;

  if (!amount_usd_cents || amount_usd_cents <= 0) {
    return new Response(JSON.stringify({ error: 'amount_usd_cents required' }), { status: 400, headers: CORS });
  }
  if (!emergency_category || !request_narrative) {
    return new Response(JSON.stringify({ error: 'emergency_category and request_narrative required' }), { status: 400, headers: CORS });
  }
  if (request_narrative.length < 100) {
    return new Response(JSON.stringify({ error: 'Please provide more detail (minimum 100 characters)' }), { status: 400, headers: CORS });
  }

  // Check pool is open for requests
  const { data: config } = await supabase
    .from('ubi_pool_config')
    .select('is_open_for_requests, max_request_pct_of_pool, max_request_usd_cents')
    .single();

  if (!config?.is_open_for_requests) {
    return new Response(JSON.stringify({ error: 'Fund is not currently accepting requests' }), { status: 400, headers: CORS });
  }

  // Check cooldown
  const { data: existing } = await supabase
    .from('ubi_withdrawal_requests')
    .select('cooldown_until, status')
    .eq('requester_user_id', user.id)
    .eq('status', 'disbursed')
    .order('disbursed_at', { ascending: false })
    .limit(1)
    .maybeSingle();

  if (existing?.cooldown_until && new Date(existing.cooldown_until) > new Date()) {
    const until = new Date(existing.cooldown_until).toLocaleDateString();
    return new Response(JSON.stringify({
      error: `You cannot submit a new request until ${until} (90-day cooldown after approval).`,
    }), { status: 400, headers: CORS });
  }

  // Check pool cap
  const { data: balance } = await supabase
    .from('ubi_pool_balance_cache')
    .select('balance_usd_cents, sim_balance_usd_cents')
    .single();

  const { data: poolConfig } = await supabase
    .from('ubi_pool_config')
    .select('mode')
    .single();

  const poolBalance = poolConfig?.mode === 'live'
    ? (balance?.balance_usd_cents ?? 0)
    : (balance?.sim_balance_usd_cents ?? 0);

  const maxByPct = Math.floor(poolBalance * Number(config.max_request_pct_of_pool));
  const cap = Math.min(maxByPct, Number(config.max_request_usd_cents));

  if (amount_usd_cents > cap) {
    const capDollars = (cap / 100).toFixed(2);
    return new Response(JSON.stringify({
      error: `Maximum request is $${capDollars} (10% of pool or $1,000, whichever is less).`,
    }), { status: 400, headers: CORS });
  }

  // Create the request
  const { data: request, error: insertError } = await supabase
    .from('ubi_withdrawal_requests')
    .insert({
      requester_user_id: user.id,
      amount_requested_usd_cents: amount_usd_cents,
      emergency_category,
      request_narrative,
      status: 'pending_ai_review',
      submitted_at: new Date().toISOString(),
      is_simulated: poolConfig?.mode !== 'live',
    })
    .select()
    .single();

  if (insertError || !request) {
    console.error('[ubi-submit-request] Insert error:', insertError?.message);
    return new Response(JSON.stringify({ error: 'Failed to create request' }), { status: 500, headers: CORS });
  }

  // Trigger AI evaluation pass 1 (async — do not await; Flutter polls status)
  fetch(`${Deno.env.get('SUPABASE_URL')}/functions/v1/ubi-ai-evaluate`, {
    method: 'POST',
    headers: {
      'Content-Type': 'application/json',
      'Authorization': `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}`,
    },
    body: JSON.stringify({ request_id: request.id, evaluation_pass: 1 }),
  }).catch((e: Error) => console.error('[ubi-submit-request] AI evaluate trigger failed:', e.message));

  return new Response(JSON.stringify({ request_id: request.id, status: 'pending_ai_review' }), {
    status: 200, headers: CORS,
  });
});
