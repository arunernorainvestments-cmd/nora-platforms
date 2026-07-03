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

import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { moderationConfigFromEnv, preGenModerate } from '../_shared/moderation.ts';
import { parsePostUrl, type ParsedSource, type Platform } from '../_shared/source_urls.ts';

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

interface SourceMeta {
  externalId: string;
  handle: string;            // creator handle → moments.creator_handle / attribution
  thumbnailUrl: string | null;
  engagement: number;        // tier signal (Hard Rule 34: tier derives from this)
  title: string;             // text context for moderation
}

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
  return json({
    moment_id: momentId,
    status: 'approved',
    platform: parsed.platform,
    creator_handle: meta.handle,
    engagement: meta.engagement,
    projected_tier: tier ?? null,   // informational; mint re-derives at mint time
    thumbnail_url: meta.thumbnailUrl,
    third_party_likeness_review: verdict.thirdPartyLikeness,
    next: 'POST cinematic-mint with this moment_id to generate the chit',
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// Live ingest — official APIs, ownership-checked (never scraping)
// ─────────────────────────────────────────────────────────────────────────────

type FetchOutcome =
  | { ok: true; meta: SourceMeta }
  | { ok: false; status: number; error: string; detail?: string };

interface Connection {
  id: string;
  platform_user_id: string;
  platform_username: string | null;
  access_token: string;
  refresh_token: string | null;
  token_expires_at: string | null;
}

async function fetchSourceMeta(
  db: SupabaseClient, parsed: ParsedSource, conn: Connection,
): Promise<FetchOutcome> {
  const token = await freshAccessToken(db, parsed.platform, conn);
  if (!token) {
    return { ok: false, status: 403, error: 'platform_token_expired', detail: `Re-link your ${parsed.platform} account` };
  }

  try {
    if (parsed.platform === 'youtube') return await fetchYouTube(parsed, conn, token);
    if (parsed.platform === 'tiktok') return await fetchTikTok(parsed, conn, token);
    return await fetchInstagram(parsed, token);
  } catch (err) {
    console.error(`moment-ingest ${parsed.platform} fetch failed:`, err);
    return { ok: false, status: 502, error: 'source_fetch_failed' };
  }
}

async function fetchYouTube(parsed: ParsedSource, conn: Connection, token: string): Promise<FetchOutcome> {
  const res = await fetch(
    `https://www.googleapis.com/youtube/v3/videos?part=snippet,statistics&id=${encodeURIComponent(parsed.externalId)}`,
    { headers: { Authorization: `Bearer ${token}` } },
  );
  if (res.status === 429) { await res.body?.cancel(); return { ok: false, status: 429, error: 'source_rate_limited' }; }
  if (!res.ok) return { ok: false, status: 502, error: 'source_fetch_failed', detail: `youtube ${res.status}` };
  const data = await res.json();
  const video = data.items?.[0];
  if (!video) return { ok: false, status: 404, error: 'post_not_found' };
  // Ownership: the video's channel must be the OAuth-linked channel.
  if (video.snippet?.channelId !== conn.platform_user_id) {
    return { ok: false, status: 403, error: 'not_your_post', detail: 'The video belongs to a different channel' };
  }
  const thumbs = video.snippet?.thumbnails ?? {};
  const thumb = thumbs.maxres?.url ?? thumbs.high?.url ?? thumbs.default?.url ?? null;
  return {
    ok: true,
    meta: {
      externalId: parsed.externalId,
      handle: `@${video.snippet?.channelTitle ?? conn.platform_username ?? 'unknown'}`,
      thumbnailUrl: thumb,
      engagement: Number(video.statistics?.viewCount ?? 0),
      title: `${video.snippet?.title ?? ''}\n${video.snippet?.description ?? ''}`.slice(0, 2000),
    },
  };
}

async function fetchTikTok(parsed: ParsedSource, conn: Connection, token: string): Promise<FetchOutcome> {
  // Display API video.query returns ONLY the authorized user's own videos —
  // an empty result for this id IS the ownership rejection.
  const res = await fetch(
    'https://open.tiktokapis.com/v2/video/query/?fields=id,title,cover_image_url,view_count,like_count',
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ filters: { video_ids: [parsed.externalId] } }),
    },
  );
  if (res.status === 429) { await res.body?.cancel(); return { ok: false, status: 429, error: 'source_rate_limited' }; }
  if (!res.ok) return { ok: false, status: 502, error: 'source_fetch_failed', detail: `tiktok ${res.status}` };
  const data = await res.json();
  const video = data.data?.videos?.[0];
  if (!video) return { ok: false, status: 403, error: 'not_your_post', detail: 'The video is not on your linked TikTok account' };
  return {
    ok: true,
    meta: {
      externalId: parsed.externalId,
      handle: `@${conn.platform_username ?? 'unknown'}`,
      thumbnailUrl: video.cover_image_url ?? null,
      engagement: Number(video.view_count ?? 0),
      title: String(video.title ?? '').slice(0, 2000),
    },
  };
}

async function fetchInstagram(parsed: ParsedSource, token: string): Promise<FetchOutcome> {
  // me/media returns only the authorized professional account's media — matching
  // the permalink shortcode against it IS the ownership check.
  let url: string | null =
    'https://graph.instagram.com/v23.0/me/media' +
    '?fields=id,permalink,media_url,thumbnail_url,like_count,comments_count,caption,username&limit=100' +
    `&access_token=${encodeURIComponent(token)}`;
  interface IgMedia {
    id?: string; permalink?: string; media_url?: string; thumbnail_url?: string;
    like_count?: number; comments_count?: number; caption?: string; username?: string;
  }
  for (let page = 0; page < 3 && url; page++) {
    const res: Response = await fetch(url);
    if (res.status === 429) { await res.body?.cancel(); return { ok: false, status: 429, error: 'source_rate_limited' }; }
    if (!res.ok) return { ok: false, status: 502, error: 'source_fetch_failed', detail: `instagram ${res.status}` };
    const data: { data?: IgMedia[]; paging?: { next?: string } } = await res.json();
    for (const media of data.data ?? []) {
      if (typeof media.permalink === 'string' && media.permalink.includes(`/${parsed.externalId}/`)) {
        return {
          ok: true,
          meta: {
            externalId: media.id ?? parsed.externalId,
            handle: `@${media.username ?? 'unknown'}`,
            thumbnailUrl: media.thumbnail_url ?? media.media_url ?? null,
            engagement: Number(media.like_count ?? 0) + Number(media.comments_count ?? 0),
            title: String(media.caption ?? '').slice(0, 2000),
          },
        };
      }
    }
    url = data.paging?.next ?? null;
  }
  return { ok: false, status: 403, error: 'not_your_post', detail: 'The post is not on your linked Instagram account' };
}

// ── token refresh (youtube/tiktok expire hourly-ish; instagram long-lived) ──────
async function freshAccessToken(
  db: SupabaseClient, platform: Platform, conn: Connection,
): Promise<string | null> {
  const expired = conn.token_expires_at !== null &&
    new Date(conn.token_expires_at).getTime() < Date.now() + 60_000;
  if (!expired) return conn.access_token;
  if (!conn.refresh_token) return platform === 'instagram' ? conn.access_token : null;

  let res: Response;
  if (platform === 'youtube') {
    res = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_id: Deno.env.get('YOUTUBE_CLIENT_ID') ?? '',
        client_secret: Deno.env.get('YOUTUBE_CLIENT_SECRET') ?? '',
        refresh_token: conn.refresh_token,
        grant_type: 'refresh_token',
      }),
    });
  } else if (platform === 'tiktok') {
    res = await fetch('https://open.tiktokapis.com/v2/oauth/token/', {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        client_key: Deno.env.get('TIKTOK_CLIENT_KEY') ?? '',
        client_secret: Deno.env.get('TIKTOK_CLIENT_SECRET') ?? '',
        refresh_token: conn.refresh_token,
        grant_type: 'refresh_token',
      }),
    });
  } else {
    return conn.access_token; // instagram long-lived tokens refresh out-of-band
  }

  if (!res.ok) {
    console.warn(`moment-ingest ${platform} token refresh failed: ${res.status}`);
    await res.body?.cancel();
    return null;
  }
  const tokens = await res.json();
  const expiresAt = tokens.expires_in
    ? new Date(Date.now() + tokens.expires_in * 1000).toISOString()
    : null;
  await db.from('platform_connections').update({
    access_token: tokens.access_token,
    refresh_token: tokens.refresh_token ?? conn.refresh_token,
    token_expires_at: expiresAt,
  }).eq('id', conn.id);
  return tokens.access_token as string;
}
