// supabase/functions/lkn-register-licensor/index.ts
//
// Self-tier licensor verification for the authenticated user.
// Requirements (Tier 1 'self'): an approved KYC record + at least one active
// linked platform. On success the user becomes a verified licensor and may
// create listings.
//
// Agent (Tier 2) and Celeb (Tier 3) tiers are NOT self-service: agents apply via
// the Partners Portal (lkn-partner-apply) and celebs are linked from the celebs
// table by N.O.R.A. staff. This endpoint rejects those tiers.
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

    // Already verified → no-op.
    const { data: profile } = await service
      .from('profiles')
      .select('lkn_licensor_status, lkn_licensor_tier')
      .eq('id', user.id)
      .maybeSingle();
    if (profile?.lkn_licensor_status === 'verified') {
      return json({ status: 'verified', tier: profile.lkn_licensor_tier, mode: 'noop' }, 200);
    }

    // ── Requirement 1: approved, unexpired KYC ──
    const { data: kyc } = await service
      .from('kyc_verifications')
      .select('id, status, expires_at')
      .eq('user_id', user.id)
      .maybeSingle();
    const kycOk = kyc?.status === 'approved' &&
      (!kyc.expires_at || new Date(kyc.expires_at as string) > new Date());
    if (!kycOk) {
      return json({ error: 'kyc_required', message: 'Complete identity verification first.' }, 403);
    }

    // ── Requirement 2: at least one active linked platform ──
    const { count: platformCount } = await service
      .from('platform_connections')
      .select('id', { count: 'exact', head: true })
      .eq('user_id', user.id)
      .eq('is_active', true);
    const linkedCount = platformCount ?? 0;
    if (linkedCount < 1) {
      return json({
        error: 'platform_required',
        message: 'Link at least one social platform to verify your likeness.',
      }, 403);
    }

    // ── Record the verification (auto-approved for self-tier) ──
    const { error: insErr } = await service.from('lkn_licensor_verifications').insert({
      user_id: user.id,
      verification_tier: 'self',
      kyc_verification_id: kyc!.id,
      linked_platform_count: linkedCount,
      status: 'approved',
      reviewed_at: new Date().toISOString(),
    });
    if (insErr) {
      console.error('lkn-register-licensor insert error:', JSON.stringify(insErr));
      return json({ error: 'Could not record verification' }, 500);
    }

    const { error: updErr } = await service.from('profiles').update({
      lkn_licensor_status: 'verified',
      lkn_licensor_tier: 'self',
      lkn_verified_at: new Date().toISOString(),
    }).eq('id', user.id);
    if (updErr) {
      console.error('lkn-register-licensor profile update error:', JSON.stringify(updErr));
      return json({ error: 'Could not update profile' }, 500);
    }

    return json({ status: 'verified', tier: 'self', linked_platform_count: linkedCount }, 200);
  } catch (err) {
    console.error('lkn-register-licensor error:', err);
    return json({ error: 'Internal server error' }, 500);
  }
});
