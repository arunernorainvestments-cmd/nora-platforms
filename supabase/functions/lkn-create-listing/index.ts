// supabase/functions/lkn-create-listing/index.ts
//
// A verified licensor creates a marketplace listing plus 1–3 price tiers.
// The listing starts in 'draft'; templates are added per-tier via lkn-submit-template,
// then the licensor submits the listing for N.O.R.A. review (status 'pending_review').
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

const CATEGORIES = new Set([
  'musician', 'athlete', 'actor', 'comedian', 'politician', 'entrepreneur',
  'influencer', 'content_creator', 'artist', 'scientist', 'other',
]);

interface TierInput {
  tier_name: string;
  tier_description?: string;
  price_usd_cents: number;
  is_exclusive?: boolean;
  max_licenses?: number | null;
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

    // Only verified licensors may list.
    const { data: profile } = await service
      .from('profiles')
      .select('lkn_licensor_status')
      .eq('id', user.id)
      .maybeSingle();
    if (profile?.lkn_licensor_status !== 'verified') {
      return json({ error: 'not_a_verified_licensor' }, 403);
    }

    let body: {
      listing_title?: string;
      listing_description?: string;
      licensor_display_name?: string;
      licensor_image_url?: string;
      category?: string;
      covers_name?: boolean;
      covers_image?: boolean;
      covers_voice?: boolean;
      covers_signature?: boolean;
      covers_persona?: boolean;
      tags?: string[];
      tiers?: TierInput[];
    };
    try { body = await req.json(); } catch { return json({ error: 'Invalid JSON body' }, 400); }

    const title = (body.listing_title ?? '').trim();
    const displayName = (body.licensor_display_name ?? '').trim();
    if (!title || !displayName) return json({ error: 'listing_title and licensor_display_name are required' }, 400);
    if (!body.category || !CATEGORIES.has(body.category)) return json({ error: 'invalid category' }, 400);

    const covers = {
      covers_name: body.covers_name ?? true,
      covers_image: body.covers_image ?? true,
      covers_voice: body.covers_voice ?? false,
      covers_signature: body.covers_signature ?? false,
      covers_persona: body.covers_persona ?? false,
    };
    if (!Object.values(covers).some(Boolean)) {
      return json({ error: 'at least one covers_* must be true' }, 400);
    }

    const tiers = body.tiers ?? [];
    if (tiers.length < 1 || tiers.length > 3) return json({ error: 'provide 1–3 tiers' }, 400);
    for (const t of tiers) {
      if (!t.tier_name || typeof t.price_usd_cents !== 'number' || t.price_usd_cents < 0) {
        return json({ error: 'each tier needs tier_name and a non-negative price_usd_cents' }, 400);
      }
    }

    // Insert listing (draft).
    const { data: listing, error: listErr } = await service
      .from('lkn_listings')
      .insert({
        licensor_user_id: user.id,
        listing_title: title,
        listing_description: body.listing_description ?? null,
        licensor_display_name: displayName,
        licensor_image_url: body.licensor_image_url ?? null,
        category: body.category,
        ...covers,
        tags: body.tags ?? [],
        status: 'draft',
      })
      .select('id')
      .single();
    if (listErr || !listing) {
      console.error('lkn-create-listing listing error:', JSON.stringify(listErr));
      return json({ error: 'Could not create listing' }, 500);
    }

    // Insert tiers.
    const tierRows = tiers.map((t) => ({
      listing_id: listing.id,
      tier_name: t.tier_name,
      tier_description: t.tier_description ?? null,
      price_usd_cents: t.price_usd_cents,
      is_exclusive: t.is_exclusive ?? false,
      max_licenses: t.max_licenses ?? null,
    }));
    const { data: insertedTiers, error: tierErr } = await service
      .from('lkn_license_tiers')
      .insert(tierRows)
      .select('id, tier_name');
    if (tierErr) {
      console.error('lkn-create-listing tiers error:', JSON.stringify(tierErr));
      return json({ error: 'Listing created but tiers failed', listing_id: listing.id }, 500);
    }

    return json({ listing_id: listing.id, tiers: insertedTiers, status: 'draft' }, 201);
  } catch (err) {
    console.error('lkn-create-listing error:', err);
    return json({ error: 'Internal server error' }, 500);
  }
});
