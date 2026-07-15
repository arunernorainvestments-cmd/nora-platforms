// supabase/functions/moment-ingest/index.ts
// M-P1 — ingestion + consent + pre-generation moderation (minting spec PHASE 1).
//
// POST { post_url, sim_engagement?, sim_title? }   (sim_* honored in sim mode only)
//
// The four layers, in order — a moderated, OWNED, attributable source before any
// generation runs:
//   Layer 1  source allowlist: tiktok / instagram / youtube URL shapes only
//            (Hard Rule 37 — no arbitrary URLs, no raw upload).
//   Layer 0  consent: the caller must have OAuth-linked the platform account
//            (platform_connections); minting is only for posts that account owns.
//   ingest   official API / oEmbed metadata: thumbnail + creator handle +
//            engagement + external id (never scraping).
//   Layer 2  pre-gen vision moderation: minor-safety ABSOLUTE (escalate, never
//            generate), nsfw/violence/hate reject, third-party-likeness flags.
//
// Result: a `moments` row with consent + verdict recorded — the row cinematic-mint
// requires to be 'approved' before it will generate anything.
//
// Sim-first per governance: MINT_INGEST_MODE=sim (default) skips external platform
// APIs (ownership gate still enforced via platform_connections) and synthesizes
// deterministic metadata; MODERATION_MODE governs the moderation layer separately.
// Deployed --no-verify-jwt (ES256 project); auth via supabase.auth.getUser().

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { moderationConfigFromEnv, preGenModerate } from '../_shared/moderation.ts';
import { parsePostUrl } from '../_shared/source_urls.ts';
import { fetchSourceMeta, type SourceMeta } from '../_shared/platform_meta.ts';

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

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { status: 200, headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) return json({ error: 'Unauthorized' }, 401);
  const anon = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!);
  const { data: { user }, error: authError } = await anon.auth.getUser(authHeader.replace('Bearer ', ''));
  if (authError || !user) return json({ error: 'Unauthorized' }, 401);

  let body: { post_url?: string; sim_engagement?: number; sim_title?: string };
  try { body = await req.json(); } catch { return json({ error: 'Invalid JSON body' }, 400); }
  if (!body.post_url?.trim()) return json({ error: 'Missing required field: post_url' }, 400);

  // ── Layer 1: source allowlist via URL shape (Hard Rule 37) ────────────────────
  const parsed = parsePostUrl(body.post_url.trim());
  if (!parsed) {
    return json({
      error: 'unsupported_source',
      detail: 'Minting accepts TikTok, Instagram, and YouTube post URLs only',
    }, 400);
  }

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  // ── Layer 0: OAuth consent — the platform account must be linked ──────────────
  const { data: conn } = await db.from('platform_connections')
    .select('id, platform_user_id, platform_username, access_token, refresh_token, token_expires_at')
    .eq('user_id', user.id).eq('platform', parsed.platform).eq('is_active', true)
    .maybeSingle();
  if (!conn) {
    return json({
      error: 'platform_not_linked',
      detail: `Link your ${parsed.platform} account before minting from it`,
    }, 403);
  }

  // ── ingest: official API / oEmbed metadata + ownership check ──────────────────
  const mode = Deno.env.get('MINT_INGEST_MODE') === 'live' ? 'live' : 'sim';
  let meta: SourceMeta;
  if (mode === 'sim') {
    meta = {
      externalId: parsed.externalId,
      handle: conn.platform_username ? `@${String(conn.platform_username).replace(/^@/, '')}` : '@sim_creator',
      thumbnailUrl: null,
      engagement: Math.max(0, Math.floor(body.sim_engagement ?? 1000)),
      title: body.sim_title ?? `sim post ${parsed.externalId}`,
    };
  } else {
    const fetched = await fetchSourceMeta(db, parsed, conn);
    if (!fetched.ok) return json({ error: fetched.error, detail: fetched.detail }, fetched.status);
    meta = fetched.meta;
  }

  // ── Layer 2: pre-gen vision moderation (minor-safety absolute) ────────────────
  const verdict = await preGenModerate(moderationConfigFromEnv(), {
    imageUrls: meta.thumbnailUrl ? [meta.thumbnailUrl] : [],
    textContext: mode === 'sim' ? (body.sim_title ?? meta.title) : meta.title,
  });
  if (verdict.reason === 'rate_limited') {
    // Hard Rule 8: log and skip — the user retries later; nothing is persisted.
    console.warn('moment-ingest: moderation rate-limited, skipping ingest');
    return json({ error: 'moderation_rate_limited', detail: 'Try again shortly' }, 429);
  }

  // ── persist: moments row (consent at link) + verdict ──────────────────────────
  const { data: momentId, error: recErr } = await db.rpc('moment_record', {
    p_owner: user.id,
    p_platform: parsed.platform,
    p_external_id: meta.externalId,
    p_url: parsed.canonicalUrl,
    p_thumbnail: meta.thumbnailUrl,
    p_engagement: meta.engagement,
    p_consent: true,
    p_handle: meta.handle,
    p_title: meta.title ?? null,
  });
  if (recErr || !momentId) return json({ error: 'moment_record failed', detail: recErr?.message }, 500);

  const { error: modErr } = await db.rpc('moment_pre_gen_moderate', {
    p_moment_id: momentId,
    p_verdict: verdict.verdict,
    p_labels: verdict.labels,
    p_third_party: verdict.thirdPartyLikeness,
    p_model: verdict.model,
  });
  if (modErr) return json({ error: 'moderation persist failed', detail: modErr.message }, 500);

  if (verdict.verdict !== 'approved') {
    // Never expose which categories fired for a blocked source (and minor-safety
    // escalations especially must be indistinguishable from a plain rejection).
    return json({
      moment_id: momentId, status: 'rejected',
      detail: 'This post did not pass content moderation and cannot be minted',
    });
  }

  const { data: tier } = await db.rpc('tier_for_engagement', { p_engagement: meta.engagement });

  // Re-linking a moment that is already mid-mint (clip staged; cutscene generated
  // and held for / cleared by a moderation verdict) must let the wizard RESUME
  // rather than force a re-upload — the wizard has no other window into this
  // state (cinematic_generations has no client RLS, deliberately), and a
  // resumed generate call completes free instead of paying for a new render.
  const { data: momentRow } = await db.from('moments')
    .select('clip_status').eq('id', momentId).single();
  const { data: resumableRows } = await db.from('cinematic_generations')
    .select('id, status').eq('moment_id', momentId)
    .in('status', ['generated', 'moderation_approved'])
    .order('created_at', { ascending: false }).limit(1);

  return json({
    moment_id: momentId,
    status: 'approved',
    platform: parsed.platform,
    creator_handle: meta.handle,
    engagement: meta.engagement,
    projected_tier: tier ?? null,   // informational; mint re-derives at mint time
    thumbnail_url: meta.thumbnailUrl,
    third_party_likeness_review: verdict.thirdPartyLikeness,
    clip_status: momentRow?.clip_status ?? null,
    // { id, status } of the newest resumable generation, or null.
    // 'moderation_approved' → Generate completes the card free;
    // 'generated' → still awaiting a human safety verdict.
    resumable_generation: resumableRows?.[0] ?? null,
    next: 'POST cinematic-mint with this moment_id to generate the chit',
  });
});

// Live ingest readers (official APIs, ownership-checked, token refresh) live in
// _shared/platform_meta.ts — shared with chit-ascension's engagement re-read.
