// supabase/functions/admin-seed-moment/index.ts
// The OPERATOR SEED LANE entry point (mig 185) — moment-ingest's stand-in for house
// content that has no social post behind it.
//
// POST { name, target_tier, brief? }   → the same payload shape moment-ingest returns,
// so the mint wizard continues into Upload → Safety → Review → Preview unchanged.
//
// Why this exists: moment-ingest's first two gates are an allowlisted post URL and an
// OAuth-linked platform_connections row (Hard Rule 37). Platform-authored cards have
// neither, so before this there was no way to exercise the CINEMATIC pipeline
// (illustration → cutscene → post-gen moderation → preview) for a card the house
// authors. mig 181's seed path stops short of generation — it bolts media on after.
//
// What is NOT relaxed:
//   * admin only — profiles.is_admin here AND re-checked in SQL (moment_mint refuses a
//     seed moment whose owner is not an admin). There is no new path for a normal user.
//   * pre-gen moderation still runs and is still recorded; the verdict is what
//     moment_mint requires. With no post there is no thumbnail, so the brief text is
//     the screened surface — and the ABSOLUTE gates live downstream regardless: the
//     uploaded clip is re-moderated at moment-clip-attach and the finished MP4 faces
//     post-gen screening (Hard Rules 37 + 39). Minor-safety is never bypassable.
//   * tier stays ladder-derived (Hard Rule 34): the operator picks a TARGET tier and
//     the RPC feeds that band's engagement FLOOR through tier_for_engagement.
//   * the resulting card is stamped is_generic + seed_source='platform' in moment_mint,
//     so it can never be listed, traded, bartered, staked, collected or ascended.
//
// Deployed --no-verify-jwt (ES256 project); auth via supabase.auth.getUser().

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { moderationConfigFromEnv, preGenModerate } from '../_shared/moderation.ts';

const corsHeaders = {
  'Access-Control-Allow-Origin': 'https://noraplatforms.com',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' },
  });

const TIERS = ['F', 'E', 'D', 'C', 'B', 'A', 'S'];

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { status: 200, headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) return json({ error: 'Unauthorized' }, 401);
  const anon = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!);
  const { data: { user }, error: authError } = await anon.auth.getUser(authHeader.replace('Bearer ', ''));
  if (authError || !user) return json({ error: 'Unauthorized' }, 401);

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  // ── gate: admin only (the SQL re-checks; this is the honest early error) ────────
  const { data: profile } = await db.from('profiles')
    .select('is_admin').eq('id', user.id).single();
  if (!profile?.is_admin) return json({ error: 'Admin only' }, 403);

  let body: { name?: string; target_tier?: string; brief?: string };
  try { body = await req.json(); } catch { return json({ error: 'Invalid JSON body' }, 400); }

  const name = body.name?.trim();
  if (!name) return json({ error: 'Missing required field: name' }, 400);
  const targetTier = (body.target_tier ?? 'C').trim().toUpperCase();
  if (!TIERS.includes(targetTier)) {
    return json({ error: 'invalid_tier', detail: `target_tier must be one of: ${TIERS.join(', ')}` }, 400);
  }
  // The brief is the ONLY screenable surface a seed moment has (no post, no
  // thumbnail) and it is what moment-classify reads to pick the family. Required so
  // moderation never runs on nothing and classification never runs blind.
  const brief = body.brief?.trim();
  if (!brief) {
    return json({
      error: 'missing_brief',
      detail: 'Describe the card in a sentence — it is what gets moderated and classified',
    }, 400);
  }

  // ── the URL-less source record, owned by this operator (mig 185) ────────────────
  const { data: momentId, error: seedErr } = await db.rpc('admin_seed_moment_operator', {
    p_operator: user.id,
    p_slug: name,
    p_target_tier: targetTier,
    p_post_title: brief,
  });
  if (seedErr || !momentId) {
    return json({ error: 'seed_failed', detail: seedErr?.message ?? 'Could not create the seed moment' }, 400);
  }

  // ── pre-gen moderation (still mandatory for house content) ──────────────────────
  const verdict = await preGenModerate(moderationConfigFromEnv(), {
    imageUrls: [],
    textContext: `${name}\n${brief}`,
  });
  if (verdict.reason === 'rate_limited') {
    // Hard Rule 8: log and skip — the operator retries; the moment stays unmoderated
    // and moment_mint refuses it until a verdict lands.
    console.warn('admin-seed-moment: moderation rate-limited');
    return json({ error: 'moderation_rate_limited', detail: 'Try again shortly' }, 429);
  }

  const { error: modErr } = await db.rpc('moment_pre_gen_moderate', {
    p_moment_id: momentId,
    p_verdict: verdict.verdict,
    p_labels: verdict.labels,
    p_third_party: verdict.thirdPartyLikeness,
    p_model: verdict.model,
  });
  if (modErr) return json({ error: 'moderation persist failed', detail: modErr.message }, 500);

  if (verdict.verdict !== 'approved') {
    return json({
      moment_id: momentId, status: 'rejected',
      detail: 'That description did not pass content moderation',
    });
  }

  const { data: tier } = await db.rpc('tier_for_engagement', { p_engagement: 0 });

  // ── resume state, mirrored from moment-ingest ───────────────────────────────────
  // Re-seeding the same name lands on the same moment, so a half-finished seed mint
  // resumes (staged clip kept, generated cutscene completed free) exactly like a
  // re-linked post does.
  const { data: momentRow } = await db.from('moments')
    .select('clip_status, engagement_count').eq('id', momentId).single();
  const { data: resumableRows } = await db.from('cinematic_generations')
    .select('id, status, requested_name').eq('moment_id', momentId)
    .in('status', ['generated', 'moderation_approved'])
    .order('created_at', { ascending: false }).limit(1);

  let draftName = (resumableRows?.[0]?.requested_name as string | null) ?? null;
  if (!draftName) {
    const { data: parkedJobs } = await db.from('mint_jobs')
      .select('provider_state').eq('moment_id', momentId).eq('status', 'running')
      .order('created_at', { ascending: false }).limit(1);
    draftName = (parkedJobs?.[0]?.provider_state as { requested_name?: string | null } | null)
      ?.requested_name ?? null;
  }

  // Re-derive the tier from what actually landed on the row, so the wizard shows the
  // ladder's answer rather than the operator's request (they agree — but the ladder
  // is the authority, Hard Rule 34).
  const { data: derivedTier } = await db.rpc('tier_for_engagement', {
    p_engagement: momentRow?.engagement_count ?? 0,
  });

  return json({
    moment_id: momentId,
    status: 'approved',
    platform: 'platform',
    is_platform_seed: true,
    creator_handle: '@nora',
    engagement: momentRow?.engagement_count ?? 0,
    projected_tier: derivedTier ?? tier ?? null,
    thumbnail_url: null,
    third_party_likeness_review: verdict.thirdPartyLikeness,
    clip_status: momentRow?.clip_status ?? null,
    resumable_generation: resumableRows?.[0] ?? null,
    draft_name: draftName,
    next: 'Upload the clip for this card, then POST cinematic-mint with this moment_id',
  });
});
