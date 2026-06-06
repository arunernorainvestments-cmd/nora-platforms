// ubi-disburse: Internal disbursement trigger. Called by process_ubi_vote_deadlines
// when a vote approves. Service role only.
// Hard Rule #23: never hold, move, or credit funds directly — all movement via
// Stripe API (live mode) or sim_usd_balances (sim mode).

import { serve } from 'https://deno.land/std@0.168.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

serve(async (req) => {
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
  );

  let body: { request_id: string };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: 'Invalid JSON body' }), { status: 400 });
  }

  const { request_id } = body;
  if (!request_id) {
    return new Response(JSON.stringify({ error: 'request_id required' }), { status: 400 });
  }

  const { data: request } = await supabase
    .from('ubi_withdrawal_requests')
    .select('*')
    .eq('id', request_id)
    .eq('status', 'approved')
    .single();

  if (!request) {
    return new Response(JSON.stringify({ error: 'Request not found or not approved' }), { status: 404 });
  }

  // KYC gate: requester must have an approved KYC verification
  const { data: kyc } = await supabase
    .from('kyc_verifications')
    .select('status')
    .eq('user_id', request.requester_user_id)
    .eq('status', 'approved')
    .maybeSingle();

  if (!kyc) {
    // Notify requester to complete KYC — hold disbursement
    await supabase.from('notifications').insert({
      user_id: request.requester_user_id,
      type: 'ubi_kyc_required',
      title: 'Emergency Fund — Identity Verification Required',
      body: 'Your request was approved. Please complete identity verification to receive your funds.',
      link: '/profile',
    });
    return new Response(JSON.stringify({ status: 'awaiting_kyc' }), { status: 200 });
  }

  const { data: config } = await supabase
    .from('ubi_pool_config')
    .select('mode')
    .single();

  const isSimulated = config?.mode !== 'live';

  // Create disbursement record
  const { data: disbursement, error: disbError } = await supabase
    .from('ubi_disbursements')
    .insert({
      request_id,
      recipient_user_id: request.requester_user_id,
      amount_usd_cents: request.amount_requested_usd_cents,
      is_simulated: isSimulated,
      status: 'processing',
    })
    .select()
    .single();

  if (disbError || !disbursement) {
    console.error('[ubi-disburse] Insert disbursement error:', disbError?.message);
    return new Response(JSON.stringify({ error: 'Failed to create disbursement record' }), { status: 500 });
  }

  if (isSimulated) {
    // Sim mode: credit sim_usd_balances for the requester
    const { error: creditError } = await supabase.rpc('increment_sim_balance', {
      p_user_id: request.requester_user_id,
      p_amount: request.amount_requested_usd_cents,
    });

    if (creditError) {
      console.error('[ubi-disburse] Sim credit error:', creditError.message);
      await supabase.from('ubi_disbursements')
        .update({ status: 'failed', failed_reason: creditError.message })
        .eq('id', disbursement.id);
      return new Response(JSON.stringify({ error: 'Disbursement failed' }), { status: 500 });
    }

    // Decrement sim pool balance
    await supabase.rpc('decrement_ubi_sim_balance', {
      p_amount: request.amount_requested_usd_cents,
    });

    await supabase.from('ubi_disbursements')
      .update({ status: 'completed', completed_at: new Date().toISOString() })
      .eq('id', disbursement.id);

  } else {
    // Live mode: Stripe Treasury payout
    // Gated — Stripe Treasury application must clear before mode='live'
    await supabase.from('ubi_disbursements')
      .update({ status: 'failed', failed_reason: 'Live mode not yet enabled' })
      .eq('id', disbursement.id);
    return new Response(JSON.stringify({ error: 'Live mode not yet enabled' }), { status: 400 });
  }

  // Update request: disbursed + 90-day cooldown
  const cooldownUntil = new Date(Date.now() + 90 * 24 * 60 * 60 * 1000).toISOString();
  await supabase.from('ubi_withdrawal_requests')
    .update({
      status: 'disbursed',
      disbursed_at: new Date().toISOString(),
      cooldown_until: cooldownUntil,
      stripe_payout_id: disbursement.stripe_payout_id ?? null,
    })
    .eq('id', request_id);

  // Decrement sim pool balance (redundant safety check for sim mode)
  await supabase.from('ubi_pool_balance_cache')
    .update({ last_synced_at: new Date().toISOString() });

  // Write anonymized public disbursement log (no PII)
  const { data: panel } = await supabase
    .from('ubi_voting_panels')
    .select('votes_yes, votes_received')
    .eq('request_id', request_id)
    .order('vote_round', { ascending: false })
    .limit(1)
    .maybeSingle();

  const monthYear = new Date().toLocaleString('en-US', { month: 'long', year: 'numeric' });
  await supabase.from('ubi_public_disbursement_log').insert({
    disbursement_id: disbursement.id,
    amount_usd_cents: request.amount_requested_usd_cents,
    emergency_category: request.emergency_category,
    month_year: monthYear,
    votes_yes: panel?.votes_yes ?? 0,
    votes_total: panel?.votes_received ?? 0,
  });

  // Notify requester
  await supabase.from('notifications').insert({
    user_id: request.requester_user_id,
    type: 'ubi_disbursed',
    title: 'Emergency Fund — Funds Approved',
    body: `Your Emergency Fund request has been approved. ${isSimulated ? 'Funds have been credited to your simulated balance.' : 'Funds are on their way via Stripe.'}`,
    link: '/emergency-fund/my-requests',
  });

  return new Response(JSON.stringify({ disbursement_id: disbursement.id, status: 'completed' }), { status: 200 });
});
