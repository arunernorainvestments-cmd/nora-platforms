// campaign-process-revenue
// Verifies a revenue event and processes distributions.
//
// Sim mode:  process_campaign_distributions() already credits sim_usd_balances
//            inline — this function just handles admin verification + triggers it.
//
// Live mode: Same RPC creates 'queued' distribution rows. This function then
//            iterates those rows and fires a Stripe Connect transfer per backer.
//            Flipping campaigns.mode from 'simulated' → 'live' in the DB is
//            the only change needed to activate the live payment rail.
//
// Request body:
//   { event_id: string, action: 'verify' | 'reject', reject_reason?: string }
//
// Auth: service-role only (admin action).

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': 'https://noraplatforms.com',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

const STRIPE_API = 'https://api.stripe.com/v1';

interface Distribution {
  id: string;
  backer_user_id: string;
  net_usd_cents: number;
  is_simulated: boolean;
  backer_stripe_account_id: string | null;
}

interface Campaign {
  mode: string;
  title: string;
  escrow_stripe_account_id: string | null;
}

// ── Stripe Connect transfer ────────────────────────────────────────────────
// Sends `amount` USD cents from the platform account to the backer's
// connected Stripe account. Called only when campaign.mode = 'live'.
async function stripeTransfer(
  stripeKey: string,
  destinationAccountId: string,
  amountCents: number,
  metadata: Record<string, string>,
): Promise<string> {
  const body = new URLSearchParams({
    amount: String(amountCents),
    currency: 'usd',
    destination: destinationAccountId,
    'metadata[distribution_id]': metadata.distribution_id,
    'metadata[campaign_id]': metadata.campaign_id,
    'metadata[backer_user_id]': metadata.backer_user_id,
  });

  const res = await fetch(`${STRIPE_API}/transfers`, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${stripeKey}`,
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body: body.toString(),
  });

  if (!res.ok) {
    const err = await res.json();
    throw new Error(`Stripe transfer failed: ${err?.error?.message ?? res.status}`);
  }

  const transfer = await res.json();
  return transfer.id as string;
}

// ── Main handler ──────────────────────────────────────────────────────────
Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { status: 200, headers: CORS_HEADERS });
  }

  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const authHeader = req.headers.get('authorization') ?? '';
  if (authHeader !== `Bearer ${serviceRoleKey}`) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), {
      status: 401,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  let body: { event_id: string; action: 'verify' | 'reject'; reject_reason?: string };
  try {
    body = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: 'Invalid JSON body' }), {
      status: 400,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  const { event_id, action, reject_reason } = body;
  if (!event_id || !action) {
    return new Response(JSON.stringify({ error: 'event_id and action are required' }), {
      status: 400,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  const db = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    serviceRoleKey,
    { auth: { persistSession: false } },
  );

  // ── Reject path ──────────────────────────────────────────────────────────
  if (action === 'reject') {
    const { error } = await db
      .from('campaign_revenue_events')
      .update({
        verification_status: 'rejected',
        dispute_reason: reject_reason ?? 'Rejected by platform',
      })
      .eq('id', event_id)
      .eq('verification_status', 'pending');

    if (error) {
      return new Response(JSON.stringify({ error: error.message }), {
        status: 500,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }
    return new Response(JSON.stringify({ ok: true, action: 'rejected' }), {
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  // ── Verify path ──────────────────────────────────────────────────────────
  // 1. Mark event verified (idempotent — already verified in sim mode)
  const { data: eventRows, error: evErr } = await db
    .from('campaign_revenue_events')
    .update({ verification_status: 'verified', verified_at: new Date().toISOString() })
    .eq('id', event_id)
    .in('verification_status', ['pending', 'verified'])
    .select('id, campaign_id, is_simulated, verification_status')
    .single();

  if (evErr || !eventRows) {
    return new Response(JSON.stringify({ error: evErr?.message ?? 'Event not found' }), {
      status: 404,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  // 2. Run distribution calculation (creates rows + pays sim immediately)
  const { data: distCount, error: distErr } = await db.rpc(
    'process_campaign_distributions',
    { p_event_id: event_id },
  );

  if (distErr) {
    // If already processed, that's fine — return success
    if (distErr.message?.includes('already created')) {
      return new Response(
        JSON.stringify({ ok: true, distributions: 0, note: 'already processed' }),
        { headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } },
      );
    }
    return new Response(JSON.stringify({ error: distErr.message }), {
      status: 500,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  // 3. Sim mode: distributions already completed inline — return early
  if (eventRows.is_simulated) {
    return new Response(
      JSON.stringify({ ok: true, mode: 'simulated', distributions: distCount }),
      { headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } },
    );
  }

  // 4. Live mode: load queued distributions and fire Stripe Connect transfers
  const stripeKey = Deno.env.get('STRIPE_SECRET_KEY');
  if (!stripeKey) {
    return new Response(
      JSON.stringify({ error: 'STRIPE_SECRET_KEY not configured for live distributions' }),
      { status: 500, headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } },
    );
  }

  const { data: campaign } = await db
    .from('campaigns')
    .select('mode, title, escrow_stripe_account_id')
    .eq('id', eventRows.campaign_id)
    .single<Campaign>();

  if (!campaign || campaign.mode !== 'live') {
    return new Response(JSON.stringify({ error: 'Campaign is not in live mode' }), {
      status: 400,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  const { data: queued, error: qErr } = await db
    .from('campaign_distributions')
    .select('id, backer_user_id, net_usd_cents, is_simulated, backer_stripe_account_id')
    .eq('revenue_event_id', event_id)
    .eq('status', 'queued')
    .returns<Distribution[]>();

  if (qErr || !queued) {
    return new Response(JSON.stringify({ error: qErr?.message ?? 'No queued distributions' }), {
      status: 500,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  const results = { completed: 0, failed: 0, skipped_no_account: 0 };

  for (const dist of queued) {
    // Skip backers without a connected Stripe account (will move to unclaimed)
    if (!dist.backer_stripe_account_id) {
      await db
        .from('campaign_distributions')
        .update({ status: 'unclaimed', failed_reason: 'No payout account linked' })
        .eq('id', dist.id);
      results.skipped_no_account++;
      continue;
    }

    // Mark processing
    await db
      .from('campaign_distributions')
      .update({ status: 'processing' })
      .eq('id', dist.id);

    try {
      const transferId = await stripeTransfer(
        stripeKey,
        dist.backer_stripe_account_id,
        dist.net_usd_cents,
        {
          distribution_id: dist.id,
          campaign_id: eventRows.campaign_id,
          backer_user_id: dist.backer_user_id,
        },
      );

      await db
        .from('campaign_distributions')
        .update({
          status: 'completed',
          stripe_transfer_id: transferId,
          distributed_at: new Date().toISOString(),
        })
        .eq('id', dist.id);

      results.completed++;
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(`Distribution ${dist.id} failed:`, msg);

      await db
        .from('campaign_distributions')
        .update({ status: 'failed', failed_reason: msg })
        .eq('id', dist.id);

      results.failed++;
    }
  }

  return new Response(
    JSON.stringify({ ok: true, mode: 'live', distributions: distCount, results }),
    { headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' } },
  );
});
