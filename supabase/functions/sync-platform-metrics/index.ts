// supabase/functions/sync-platform-metrics/index.ts
// Fetches live metrics from YouTube and Twitch for all active connections
// (or a single user). Computes Heat Score and upserts into platform_metrics.
// Triggered by pg_cron every 5 minutes and on-demand after OAuth callback.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': 'https://nora-platforms.vercel.app',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
};

interface PlatformConnection {
  id: string;
  user_id: string;
  platform: string;
  platform_user_id: string;
  platform_username: string | null;
  access_token: string;
  refresh_token: string | null;
  token_expires_at: string | null;
}

interface PlatformMetrics {
  isLive: boolean;
  liveViewers: number;
  followers: number;
  subscriberCount?: number;
  streamTitle?: string;
  streamCategory?: string;
  raw: Record<string, unknown>;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { status: 200, headers: corsHeaders });
  }
  if (req.method !== 'POST' && req.method !== 'GET') {
    return json({ error: 'Method not allowed' }, 405, corsHeaders);
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    { auth: { persistSession: false } },
  );

  // Optional: scope to a single user if user_id is provided
  let targetUserId: string | null = null;
  if (req.method === 'POST') {
    try {
      const body = await req.json();
      targetUserId = body.user_id ?? null;
    } catch {
      // No body or not JSON — sync all
    }
  }

  // ── Fetch active connections ──────────────────────────────────────────────
  let query = supabase
    .from('platform_connections')
    .select('id, user_id, platform, platform_user_id, platform_username, access_token, refresh_token, token_expires_at')
    .eq('is_active', true)
    .in('platform', ['youtube', 'twitch']);

  if (targetUserId) {
    query = query.eq('user_id', targetUserId);
  }

  const { data: connections, error: connErr } = await query;
  if (connErr) {
    console.error('[sync-platform-metrics] Fetch connections error:', connErr.message);
    return json({ error: connErr.message }, 500, corsHeaders);
  }
  if (!connections || connections.length === 0) {
    return json({ synced: 0, message: 'No active connections' }, 200, corsHeaders);
  }

  const results: Array<{ user_id: string; platform: string; success: boolean; error?: string }> = [];

  for (const conn of connections as PlatformConnection[]) {
    try {
      // ── Refresh token if expired ────────────────────────────────────────
      let accessToken = conn.access_token;
      if (conn.token_expires_at && conn.refresh_token) {
        const expiresAt = new Date(conn.token_expires_at).getTime();
        if (expiresAt - Date.now() < 5 * 60 * 1000) {
          // Expires within 5 minutes — refresh now
          const refreshed = await refreshAccessToken(conn.platform, conn.refresh_token);
          if (refreshed) {
            accessToken = refreshed.access_token;
            const newExpiry = refreshed.expires_in
              ? new Date(Date.now() + refreshed.expires_in * 1000).toISOString()
              : null;
            await supabase
              .from('platform_connections')
              .update({
                access_token: refreshed.access_token,
                refresh_token: refreshed.refresh_token ?? conn.refresh_token,
                token_expires_at: newExpiry,
                last_synced_at: new Date().toISOString(),
              })
              .eq('id', conn.id);
          }
        }
      }

      // ── Fetch platform metrics ──────────────────────────────────────────
      const metrics =
        conn.platform === 'youtube'
          ? await fetchYouTubeMetrics(conn.platform_user_id, accessToken)
          : await fetchTwitchMetrics(conn.platform_user_id, accessToken);

      // ── Upsert platform_metrics ─────────────────────────────────────────
      const { error: upsertErr } = await supabase
        .from('platform_metrics')
        .upsert(
          {
            platform_connection_id: conn.id,
            user_id: conn.user_id,
            platform: conn.platform,
            is_live: metrics.isLive,
            live_viewer_count: metrics.liveViewers,
            follower_count: metrics.followers,
            subscriber_count: metrics.subscriberCount ?? 0,
            stream_title: metrics.streamTitle ?? null,
            stream_category: metrics.streamCategory ?? null,
            heat_score: computeHeatScore(metrics),
            raw_metrics: metrics.raw,
            fetched_at: new Date().toISOString(),
          },
          { onConflict: 'platform_connection_id' },
        );

      if (upsertErr) throw new Error(upsertErr.message);

      // Update last_synced_at on connection
      await supabase
        .from('platform_connections')
        .update({ last_synced_at: new Date().toISOString() })
        .eq('id', conn.id);

      results.push({ user_id: conn.user_id, platform: conn.platform, success: true });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(`[sync-platform-metrics] ${conn.platform}/${conn.user_id} failed:`, msg);
      results.push({ user_id: conn.user_id, platform: conn.platform, success: false, error: msg });
    }
  }

  const synced = results.filter((r) => r.success).length;
  return json({ synced, total: results.length, results }, 200, corsHeaders);
});

// ─────────────────────────────────────────────────────────────────────────────
// Heat Score Formula
// ─────────────────────────────────────────────────────────────────────────────

function computeHeatScore(metrics: PlatformMetrics): number {
  const PLATFORM_AVG_LIVE = 500;

  const liveComponent = metrics.isLive
    ? Math.min((metrics.liveViewers / PLATFORM_AVG_LIVE) * 60, 60)
    : 0;

  const reachComponent = Math.min((metrics.followers / 1_000_000) * 25, 25);

  const liveBonusComponent = metrics.isLive ? 15 : 0;

  return Math.min(
    Math.round((liveComponent + reachComponent + liveBonusComponent) * 100) / 100,
    100,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// YouTube API
// ─────────────────────────────────────────────────────────────────────────────

async function fetchYouTubeMetrics(
  channelId: string,
  accessToken: string,
): Promise<PlatformMetrics> {
  const baseHeaders = { Authorization: `Bearer ${accessToken}` };

  // 1. Channel statistics
  const channelRes = await fetch(
    `https://www.googleapis.com/youtube/v3/channels?part=statistics,snippet&mine=true`,
    { headers: baseHeaders },
  );
  if (!channelRes.ok) throw new Error(`YouTube channels API ${channelRes.status}`);
  const channelData = await channelRes.json();
  const channel = channelData.items?.[0];
  const subscribers = parseInt(channel?.statistics?.subscriberCount ?? '0', 10);

  // 2. Check for active live broadcast
  const searchRes = await fetch(
    `https://www.googleapis.com/youtube/v3/search?part=snippet&channelId=${channelId}&type=video&eventType=live&maxResults=1`,
    { headers: baseHeaders },
  );
  if (!searchRes.ok) throw new Error(`YouTube search API ${searchRes.status}`);
  const searchData = await searchRes.json();
  const liveItem = searchData.items?.[0];

  if (!liveItem) {
    return {
      isLive: false,
      liveViewers: 0,
      followers: subscribers,
      subscriberCount: subscribers,
      raw: { channel: channelData, search: searchData },
    };
  }

  // 3. Get concurrent viewers for live video
  const videoId = liveItem.id?.videoId as string;
  const videoRes = await fetch(
    `https://www.googleapis.com/youtube/v3/videos?part=liveStreamingDetails,snippet&id=${videoId}`,
    { headers: baseHeaders },
  );
  if (!videoRes.ok) throw new Error(`YouTube videos API ${videoRes.status}`);
  const videoData = await videoRes.json();
  const video = videoData.items?.[0];
  const concurrentViewers = parseInt(
    video?.liveStreamingDetails?.concurrentViewers ?? '0',
    10,
  );

  return {
    isLive: true,
    liveViewers: concurrentViewers,
    followers: subscribers,
    subscriberCount: subscribers,
    streamTitle: (video?.snippet?.title ?? null) as string | undefined,
    raw: { channel: channelData, video: videoData },
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Twitch API
// ─────────────────────────────────────────────────────────────────────────────

async function fetchTwitchMetrics(
  twitchUserId: string,
  accessToken: string,
): Promise<PlatformMetrics> {
  const clientId = Deno.env.get('TWITCH_CLIENT_ID') ?? '';
  const twitchHeaders = {
    Authorization: `Bearer ${accessToken}`,
    'Client-Id': clientId,
  };

  // 1. Follower count
  const followersRes = await fetch(
    `https://api.twitch.tv/helix/channels/followers?broadcaster_id=${twitchUserId}`,
    { headers: twitchHeaders },
  );
  if (!followersRes.ok) throw new Error(`Twitch followers API ${followersRes.status}`);
  const followersData = await followersRes.json();
  const followers = (followersData.total as number) ?? 0;

  // 2. Stream status
  const streamRes = await fetch(
    `https://api.twitch.tv/helix/streams?user_id=${twitchUserId}`,
    { headers: twitchHeaders },
  );
  if (!streamRes.ok) throw new Error(`Twitch streams API ${streamRes.status}`);
  const streamData = await streamRes.json();
  const stream = streamData.data?.[0];

  if (!stream) {
    return {
      isLive: false,
      liveViewers: 0,
      followers,
      raw: { followers: followersData, stream: streamData },
    };
  }

  return {
    isLive: true,
    liveViewers: (stream.viewer_count as number) ?? 0,
    followers,
    streamTitle: (stream.title as string) ?? undefined,
    streamCategory: (stream.game_name as string) ?? undefined,
    raw: { followers: followersData, stream: streamData },
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Token refresh
// ─────────────────────────────────────────────────────────────────────────────

async function refreshAccessToken(
  platform: string,
  refreshToken: string,
): Promise<{ access_token: string; refresh_token?: string; expires_in?: number } | null> {
  try {
    if (platform === 'youtube') {
      const res = await fetch('https://oauth2.googleapis.com/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          client_id: Deno.env.get('YOUTUBE_CLIENT_ID') ?? '',
          client_secret: Deno.env.get('YOUTUBE_CLIENT_SECRET') ?? '',
          refresh_token: refreshToken,
          grant_type: 'refresh_token',
        }),
      });
      if (!res.ok) return null;
      return res.json();
    } else {
      // twitch
      const res = await fetch('https://id.twitch.tv/oauth2/token', {
        method: 'POST',
        headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
        body: new URLSearchParams({
          client_id: Deno.env.get('TWITCH_CLIENT_ID') ?? '',
          client_secret: Deno.env.get('TWITCH_CLIENT_SECRET') ?? '',
          refresh_token: refreshToken,
          grant_type: 'refresh_token',
        }),
      });
      if (!res.ok) return null;
      return res.json();
    }
  } catch {
    return null;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

function json(
  body: unknown,
  status: number,
  extraHeaders: Record<string, string> = {},
): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json', ...extraHeaders },
  });
}
