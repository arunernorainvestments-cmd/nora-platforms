// supabase/functions/nora-arena-api-profile/index.ts
//
// doc6 mobile-API convenience endpoint: returns the authenticated user's
// profile + scores + stat sheet + token balance + active license holdings in a
// single round-trip (the mobile Profile Mini-Card + character-select gating).
//
// NOT a new data source — it aggregates existing tables so the nora-arena app
// avoids 4+ separate Supabase queries per screen load. Auth is the Supabase
// session JWT (same account as the web app). Deploy WITH jwt verification.
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'GET, OPTIONS',
};

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json' },
  });
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'GET') return json({ error: 'Method not allowed' }, 405);

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

    // Aggregate in parallel.
    const [profileRes, metricsRes, statRes, balanceRes, licenseRes] = await Promise.all([
      service.from('profiles')
        .select('id, username, display_name, avatar_url, bio, is_creator, is_market_maker')
        .eq('id', user.id).maybeSingle(),
      service.from('platform_metrics')
        .select('display_score, heat_score')
        .eq('user_id', user.id),
      service.from('creator_stat_sheets')
        .select('*')
        .eq('user_id', user.id).maybeSingle(),
      service.from('token_balances')
        .select('available_tokens, lifetime_earned, lifetime_spent')
        .eq('user_id', user.id).maybeSingle(),
      // Active licenses this user holds (their own — safe to return to the owner).
      service.from('lkn_agreements')
        .select('license_id, status, listing_id, effective_date, expiration_date')
        .eq('licensee_user_id', user.id)
        .eq('status', 'active'),
    ]);

    // display_score is additive across platform rows; heat_score is the max
    // (mirrors compute-spotlight so the mobile number matches the web Spotlight).
    let displayScore = 0;
    let heatScore = 0;
    for (const m of metricsRes.data ?? []) {
      displayScore += (m.display_score as number | null) ?? 0;
      heatScore = Math.max(heatScore, (m.heat_score as number | null) ?? 0);
    }

    return json({
      profile: {
        nora_id: user.id,
        username: profileRes.data?.username ?? null,
        display_name: profileRes.data?.display_name ?? null,
        avatar_url: profileRes.data?.avatar_url ?? null,
        bio: profileRes.data?.bio ?? null,
        is_creator: profileRes.data?.is_creator ?? false,
        is_market_maker: profileRes.data?.is_market_maker ?? false,
        display_score: displayScore,
        heat_score: heatScore,
      },
      stat_sheet: statRes.data ?? null,
      token_balance: {
        available_tokens: balanceRes.data?.available_tokens ?? 0,
        lifetime_earned: balanceRes.data?.lifetime_earned ?? 0,
        lifetime_spent: balanceRes.data?.lifetime_spent ?? 0,
      },
      license_holdings: (licenseRes.data ?? []).map((l) => ({
        license_id: l.license_id,
        status: l.status,
        listing_id: l.listing_id,
        effective_date: l.effective_date,
        expiration_date: l.expiration_date,
      })),
    }, 200);
  } catch (err) {
    console.error('nora-arena-api-profile error:', err);
    return json({ error: 'Internal server error' }, 500);
  }
});
