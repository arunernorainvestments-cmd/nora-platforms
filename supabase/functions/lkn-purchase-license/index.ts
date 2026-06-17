// supabase/functions/lkn-purchase-license/index.ts
//
// The authenticated user (licensee) purchases a license tier.
// Sim mode (default): creates the agreement immediately with is_simulated = true.
// Live mode (LKN_PAYMENTS=live): Stripe Checkout is required — returns 501 until wired.
//
// Creates an APPEND-ONLY lkn_agreements row (Hard Rule 29) with:
//   - terms_snapshot: full copy of the template at purchase time (verification
//     reads this, never the live template)
//   - record_hash: SHA-256 over the core license fields
// 5% platform commission is deducted before the licensor's share.
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': 'https://noraplatforms.com',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

async function sha256Hex(obj: unknown): Promise<string> {
  const bytes = new TextEncoder().encode(JSON.stringify(obj));
  const buf = await crypto.subtle.digest('SHA-256', bytes);
  return 'sha256:' + Array.from(new Uint8Array(buf)).map((b) => b.toString(16).padStart(2, '0')).join('');
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  try {
    const authHeader = req.headers.get('Authorization');
    if (!authHeader) return json({ error: 'Missing authorization header' }, 401);

    const supabase = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_ANON_KEY')!,
      { global: { headers: { Authorization: authHeader } } },
    );
    const { data: { user }, error: authError } = await supabase.auth.getUser();
    if (authError || !user) return json({ error: 'Unauthorized' }, 401);

    const service = createClient(
      Deno.env.get('SUPABASE_URL')!,
      Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
    );

    let body: { tier_id?: string; agreed?: boolean };
    try { body = await req.json(); } catch { return json({ error: 'Invalid JSON body' }, 400); }
    if (!body.tier_id) return json({ error: 'tier_id is required' }, 400);
    if (body.agreed !== true) return json({ error: 'must agree to the license terms' }, 400);

    // Load tier + its listing + its template.
    const { data: tier } = await service
      .from('lkn_license_tiers')
      .select('id, listing_id, price_usd_cents, is_active, max_licenses, licenses_sold')
      .eq('id', body.tier_id)
      .maybeSingle();
    if (!tier || !tier.is_active) return json({ error: 'tier not available' }, 404);

    const { data: listing } = await service
      .from('lkn_listings')
      .select('id, licensor_user_id, status')
      .eq('id', tier.listing_id)
      .maybeSingle();
    if (!listing || listing.status !== 'active') return json({ error: 'listing not active' }, 404);
    if (listing.licensor_user_id === user.id) return json({ error: 'cannot license your own likeness' }, 400);

    const { data: template } = await service
      .from('lkn_license_templates')
      .select('*')
      .eq('tier_id', tier.id)
      .maybeSingle();
    if (!template) return json({ error: 'tier has no published terms' }, 409);

    // Supply check + atomic reservation (optimistic CAS on licenses_sold).
    if (tier.max_licenses != null) {
      if ((tier.licenses_sold as number) >= (tier.max_licenses as number)) {
        return json({ error: 'sold_out' }, 409);
      }
      const { data: reserved, error: casErr } = await service
        .from('lkn_license_tiers')
        .update({ licenses_sold: (tier.licenses_sold as number) + 1 })
        .eq('id', tier.id)
        .eq('licenses_sold', tier.licenses_sold) // CAS guard
        .lt('licenses_sold', tier.max_licenses)
        .select('id');
      if (casErr || !reserved || reserved.length === 0) {
        return json({ error: 'sold_out_or_contended', message: 'Please retry.' }, 409);
      }
    } else {
      await service.from('lkn_license_tiers')
        .update({ licenses_sold: (tier.licenses_sold as number) + 1 })
        .eq('id', tier.id);
    }

    const liveMode = (Deno.env.get('LKN_PAYMENTS') ?? 'sim') === 'live';
    if (liveMode) {
      // Live payments require Stripe Checkout + webhook finalization (not yet wired).
      // Roll back the reservation we just took.
      await service.from('lkn_license_tiers')
        .update({ licenses_sold: tier.licenses_sold }).eq('id', tier.id);
      return json({ error: 'live_payments_not_configured' }, 501);
    }

    // ── Pricing: 5% platform commission ──
    const price = tier.price_usd_cents as number;
    const platformFee = Math.round(price * 0.05);
    const licensorReceives = price - platformFee;

    // ── Expiration from template duration ──
    let expiration: string | null = null;
    if (template.duration_type === 'fixed' && template.expires_at) {
      expiration = new Date(template.expires_at as string).toISOString().slice(0, 10);
    }

    const effectiveDate = new Date().toISOString().slice(0, 10);
    const coreForHash = {
      listing_id: listing.id, tier_id: tier.id, template_id: template.id,
      licensor: listing.licensor_user_id, licensee: user.id,
      effective_date: effectiveDate, expiration_date: expiration,
      price_paid_usd_cents: price,
    };
    const recordHash = await sha256Hex(coreForHash);

    // Insert agreement. license_id is DB-generated; retry once on the
    // (astronomically unlikely) UNIQUE collision.
    let agreement = null;
    for (let attempt = 0; attempt < 2 && !agreement; attempt++) {
      const { data, error } = await service.from('lkn_agreements').insert({
        listing_id: listing.id,
        tier_id: tier.id,
        template_id: template.id,
        licensor_user_id: listing.licensor_user_id,
        licensee_user_id: user.id,
        terms_snapshot: template,
        effective_date: effectiveDate,
        expiration_date: expiration,
        status: 'active',
        price_paid_usd_cents: price,
        platform_fee_usd_cents: platformFee,
        licensor_receives_usd_cents: licensorReceives,
        is_simulated: true,
        record_hash: recordHash,
      }).select('id, license_id').single();
      if (!error) { agreement = data; break; }
      if (!String(error.message).includes('license_id')) {
        console.error('lkn-purchase-license insert error:', JSON.stringify(error));
        return json({ error: 'Could not create license' }, 500);
      }
    }
    if (!agreement) return json({ error: 'Could not allocate a license id, retry' }, 500);

    await service.from('lkn_agreement_events').insert({
      agreement_id: agreement.id, event_type: 'created', actor_user_id: user.id,
      notes: 'sim-mode purchase',
    });

    return json({
      license_id: agreement.license_id,
      status: 'active',
      effective_date: effectiveDate,
      expiration_date: expiration,
      price_paid_usd_cents: price,
      platform_fee_usd_cents: platformFee,
      licensor_receives_usd_cents: licensorReceives,
      public_record_url: `https://noraplatforms.com/license/${agreement.license_id}`,
      is_simulated: true,
    }, 201);
  } catch (err) {
    console.error('lkn-purchase-license error:', err);
    return json({ error: 'Internal server error' }, 500);
  }
});
