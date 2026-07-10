// supabase/functions/_shared/platform_meta.ts
// Live source-post metadata via the OFFICIAL platform APIs, ownership-checked —
// never scraping (Hard Rule 37). Extracted from moment-ingest so the ascension
// refresh (chit-ascension) re-reads engagement through the exact same readers:
//   - youtube: videos.list, channel must match the OAuth-linked channel
//   - tiktok:  video.query returns only the authorized user's own videos
//   - instagram: me/media permalink match IS the ownership check
// Token refresh included (youtube/tiktok expire hourly-ish; instagram long-lived).

import type { SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';
import type { Platform } from './source_urls.ts';

export interface SourceRef {
  platform: Platform;
  externalId: string;
}

export interface SourceMeta {
  externalId: string;
  handle: string;            // creator handle → moments.creator_handle / attribution
  thumbnailUrl: string | null;
  engagement: number;        // tier signal (Hard Rule 34: tier derives from this)
  title: string;             // text context for moderation
}

export interface Connection {
  id: string;
  platform_user_id: string;
  platform_username: string | null;
  access_token: string;
  refresh_token: string | null;
  token_expires_at: string | null;
}

export type FetchOutcome =
  | { ok: true; meta: SourceMeta }
  | { ok: false; status: number; error: string; detail?: string };

export async function fetchSourceMeta(
  db: SupabaseClient, source: SourceRef, conn: Connection,
): Promise<FetchOutcome> {
  const token = await freshAccessToken(db, source.platform, conn);
  if (!token) {
    return { ok: false, status: 403, error: 'platform_token_expired', detail: `Re-link your ${source.platform} account` };
  }

  try {
    if (source.platform === 'youtube') return await fetchYouTube(source, conn, token);
    if (source.platform === 'tiktok') return await fetchTikTok(source, conn, token);
    return await fetchInstagram(source, token);
  } catch (err) {
    console.error(`platform_meta ${source.platform} fetch failed:`, err);
    return { ok: false, status: 502, error: 'source_fetch_failed' };
  }
}

async function fetchYouTube(source: SourceRef, conn: Connection, token: string): Promise<FetchOutcome> {
  const res = await fetch(
    `https://www.googleapis.com/youtube/v3/videos?part=snippet,statistics&id=${encodeURIComponent(source.externalId)}`,
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
      externalId: source.externalId,
      handle: `@${video.snippet?.channelTitle ?? conn.platform_username ?? 'unknown'}`,
      thumbnailUrl: thumb,
      engagement: Number(video.statistics?.viewCount ?? 0),
      title: `${video.snippet?.title ?? ''}\n${video.snippet?.description ?? ''}`.slice(0, 2000),
    },
  };
}

async function fetchTikTok(source: SourceRef, conn: Connection, token: string): Promise<FetchOutcome> {
  // Display API video.query returns ONLY the authorized user's own videos —
  // an empty result for this id IS the ownership rejection.
  const res = await fetch(
    'https://open.tiktokapis.com/v2/video/query/?fields=id,title,cover_image_url,view_count,like_count',
    {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({ filters: { video_ids: [source.externalId] } }),
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
      externalId: source.externalId,
      handle: `@${conn.platform_username ?? 'unknown'}`,
      thumbnailUrl: video.cover_image_url ?? null,
      engagement: Number(video.view_count ?? 0),
      title: String(video.title ?? '').slice(0, 2000),
    },
  };
}

async function fetchInstagram(source: SourceRef, token: string): Promise<FetchOutcome> {
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
      if (typeof media.permalink === 'string' && media.permalink.includes(`/${source.externalId}/`)) {
        return {
          ok: true,
          meta: {
            externalId: media.id ?? source.externalId,
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
export async function freshAccessToken(
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
    console.warn(`platform_meta ${platform} token refresh failed: ${res.status}`);
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
