// ubi-contribute: Anonymous or authenticated contribution to the Emergency Fund.
// Deploy with --no-verify-jwt (public endpoint, no account required).
// Sim mode: increments pool balance cache and creates confirmed contribution.
// Live mode: creates Stripe Checkout session (gated by ubi_pool_config.mode = 'live').

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  );

  // Optional auth — contributions are allowed without an account
  const authHeader = req.headers.get('Authorization');
  let userId: string | null = null;
  if (authHeader) {
    const anonClient = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } }
    );
    const { data: { user } } = await anonClient.auth.getUser();
    userId = user?.id ?? null;
  }

  let body: {
    amount_usd_cents: number;
    is_recurring: boolean;
    contributor_email?: string;
    is_anonymous_display: boolean;
  };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
      status: 400, headers: CORS,
    });
  }

  const { amount_usd_cents, is_recurring, contributor_email, is_anonymous_display } = body;

  if (!amount_usd_cents || amount_usd_cents < 100) {
    return new Response(JSON.stringify({ error: 'Minimum contribution is $1.00' }), {
      status: 400, headers: CORS,
    });
  }

  if (!userId && !contributor_email) {
    return new Response(JSON.stringify({ error: 'contributor_email required for anonymous contributions' }), {
      status: 400, headers: CORS,
    });
  }

  const { data: config } = await supabase
    .from('ubi_pool_config')
    .select('mode, is_open_for_contributions')
    .single();

  if (!config?.is_open_for_contributions) {
    return new Response(JSON.stringify({ error: 'Contributions are temporarily paused' }), {
      status: 400, headers: CORS,
    });
  }

  if (config.mode === 'live') {
    // Live mode: create Stripe Checkout session
    // Stripe Treasury must be approved before setting mode='live'
    return new Response(JSON.stringify({ error: 'Live mode not yet enabled' }), {
      status: 400, headers: CORS,
    });
  }

  // Simulated mode: directly confirm contribution and increment pool balance
  const { data: contribution, error: insertError } = await supabase
    .from('ubi_pool_contributions')
    .insert({
      user_id: userId,
      contributor_email: userId ? null : contributor_email,
      amount_usd_cents,
      is_recurring,
      is_simulated: true,
      is_anonymous_display,
      status: 'confirmed',
      confirmed_at: new Date().toISOString(),
    })
    .select()
    .single();

  if (insertError) {
    console.error('[ubi-contribute] Insert error:', insertError.message);
    return new Response(JSON.stringify({ error: 'Failed to record contribution' }), {
      status: 500, headers: CORS,
    });
  }

  // Update sim pool balance
  await supabase.rpc('increment_ubi_sim_balance', { p_amount: amount_usd_cents });

  return new Response(JSON.stringify({
    contribution_id: contribution.id,
    mode: 'simulated',
  }), { status: 200, headers: CORS });
});
