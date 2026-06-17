// supabase/functions/lkn-submit-template/index.ts
//
// A verified licensor submits the toggle parameters for one tier of their listing.
// Upserts lkn_license_templates (one per tier). Whitelists known fields only.
// After a template is saved, the licensor may submit the listing for review
// (?submit_for_review=true moves the listing draft → pending_review).
//
// NOTE: this stores the parameters. Contract text is generated separately by
// lkn-generate-contract from the pre-approved clause library (never here).
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

// Fields a licensor may set, by type. Everything else is ignored.
const BOOL_FIELDS = [
  'purpose_ai_generated_content', 'purpose_ai_voice_cloning', 'purpose_ai_image_generation',
  'purpose_ai_model_training', 'purpose_commercial_advertising', 'purpose_entertainment_film',
  'purpose_entertainment_tv', 'purpose_entertainment_game', 'purpose_music',
  'purpose_social_media', 'purpose_merchandise', 'purpose_nft_digital_asset',
  'restrict_profanity', 'restrict_adult_content', 'restrict_political_content',
  'restrict_religious_content', 'restrict_violence', 'restrict_substance_use',
  'restrict_competitor_brands', 'ai_generated_must_be_labeled',
  'sublicensing_allowed', 'sublicensing_requires_approval',
  'approval_required_before_publish', 'approval_required_before_commercial_release',
];
const TEXT_FIELDS = [
  'duration_type', 'project_description', 'territory', 'purpose_custom_description',
  'approval_contact_email', 'revenue_share_applies_to', 'revocation_type',
  'addendum_storage_path', 'addendum_description',
];
const ARRAY_FIELDS = ['territory_countries', 'restricted_topics'];
const INT_FIELDS = ['ai_max_generated_instances'];

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

    // deno-lint-ignore no-explicit-any
    let body: any;
    try { body = await req.json(); } catch { return json({ error: 'Invalid JSON body' }, 400); }

    const tierId = body.tier_id;
    if (!tierId) return json({ error: 'tier_id is required' }, 400);

    // Verify the tier belongs to a listing owned by this user.
    const { data: tier } = await service
      .from('lkn_license_tiers')
      .select('id, listing_id, lkn_listings!inner(licensor_user_id)')
      .eq('id', tierId)
      .maybeSingle();
    // deno-lint-ignore no-explicit-any
    const ownerId = (tier as any)?.lkn_listings?.licensor_user_id;
    if (!tier || ownerId !== user.id) {
      return json({ error: 'tier not found or not owned by you' }, 403);
    }

    // Build a whitelisted row.
    // deno-lint-ignore no-explicit-any
    const row: Record<string, any> = { tier_id: tierId, listing_id: tier.listing_id, updated_at: new Date().toISOString() };
    const params = body.params ?? body; // accept either {params:{...}} or flat
    for (const f of BOOL_FIELDS) if (typeof params[f] === 'boolean') row[f] = params[f];
    for (const f of TEXT_FIELDS) if (typeof params[f] === 'string') row[f] = params[f];
    for (const f of ARRAY_FIELDS) if (Array.isArray(params[f])) row[f] = params[f];
    for (const f of INT_FIELDS) if (Number.isInteger(params[f])) row[f] = params[f];
    if (typeof params.expires_at === 'string') row.expires_at = params.expires_at;
    if (typeof params.revenue_share_pct === 'number') row.revenue_share_pct = params.revenue_share_pct;

    // Validate duration coupling.
    if (row.duration_type === 'fixed' && !row.expires_at) {
      return json({ error: 'expires_at is required when duration_type = fixed' }, 400);
    }

    const { data: saved, error: upErr } = await service
      .from('lkn_license_templates')
      .upsert(row, { onConflict: 'tier_id' })
      .select('id')
      .single();
    if (upErr || !saved) {
      console.error('lkn-submit-template upsert error:', JSON.stringify(upErr));
      return json({ error: 'Could not save template' }, 500);
    }

    // Optionally move the listing into review.
    const url = new URL(req.url);
    if (url.searchParams.get('submit_for_review') === 'true') {
      await service.from('lkn_listings')
        .update({ status: 'pending_review' })
        .eq('id', tier.listing_id)
        .eq('licensor_user_id', user.id)
        .eq('status', 'draft');
    }

    return json({ template_id: saved.id, tier_id: tierId }, 200);
  } catch (err) {
    console.error('lkn-submit-template error:', err);
    return json({ error: 'Internal server error' }, 500);
  }
});
