// supabase/functions/sync-platform-metrics/index.ts
// Fetches live metrics from YouTube, Twitch, and X for all active connections
// (or a single user). Computes Display Score (bigint, additive raw points) and
// Heat Score (boost-only, baseline 0).
// Triggered by pg_cron every 5 minutes and on-demand after OAuth callback.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Origin': 'https://noraplatforms.com',
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
  recentPostViews?: number;   // X only
  recentPostReposts?: number; // X only
  recentPostLikes?: number;   // X only
  savedTracks?: number;       // Spotify only (stored in recent_post_views column)
  savedAlbums?: number;       // Spotify only (stored in recent_post_reposts column)
  raw: Record<string, unknown>;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { status: 200, headers: corsHeaders });
  }
  if (req.method !== 'POST' && req.method !== 'GET') {
    return json({ error: 'Method not allowed' }, 405, corsHeaders);
  }

  // ── Auth gate ─────────────────────────────────────────────────────────────
  // Accept: service role Bearer (oauth-callback, pg_cron) OR SYNC_SECRET header.
  // Rejects unauthenticated requests so the open URL cannot be abused.
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const syncSecret     = Deno.env.get('SYNC_SECRET') ?? '';
  const authHeader     = req.headers.get('authorization') ?? '';
  const secretHeader   = req.headers.get('x-sync-secret') ?? '';

  const isServiceRole  = authHeader === `Bearer ${serviceRoleKey}`;
  const hasValidSecret = syncSecret.length > 0 && secretHeader === syncSecret;

  if (!isServiceRole && !hasValidSecret) {
    console.warn('[sync-platform-metrics] Rejected unauthorized request');
    return json({ error: 'Unauthorized' }, 401, corsHeaders);
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    serviceRoleKey,
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

  // ── Fetch active connections (with 4-minute cooldown) ────────────────────
  // Skip connections synced within the last 4 minutes to prevent API quota
  // exhaustion. NULL last_synced_at (new connections) always pass through.
  const cooldownCutoff = new Date(Date.now() - 4 * 60 * 1000).toISOString();

  let query = supabase
    .from('platform_connections')
    .select('id, user_id, platform, platform_user_id, platform_username, access_token, refresh_token, token_expires_at')
    .eq('is_active', true)
    .in('platform', ['youtube', 'twitch', 'x', 'spotify'])
    .or(`last_synced_at.is.null,last_synced_at.lt.${cooldownCutoff}`);

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
  // Track which user_ids were processed so we can write composite score_history entries
  const processedUserIds = new Set<string>();

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
      let metrics: PlatformMetrics;
      if (conn.platform === 'youtube') {
        metrics = await fetchYouTubeMetrics(conn.platform_user_id, accessToken);
      } else if (conn.platform === 'twitch') {
        metrics = await fetchTwitchMetrics(conn.platform_user_id, accessToken);
      } else if (conn.platform === 'spotify') {
        try {
          metrics = await fetchSpotifyMetrics(conn.platform_user_id, accessToken);
        } catch (err) {
          // Retry once with a fresh token on 401
          if (err instanceof Error && err.message.startsWith('Spotify 401') && conn.refresh_token) {
            const refreshed = await refreshAccessToken('spotify', conn.refresh_token);
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
                })
                .eq('id', conn.id);
              metrics = await fetchSpotifyMetrics(conn.platform_user_id, accessToken);
            } else throw err;
          } else throw err;
        }
      } else {
        // x
        metrics = await fetchXMetrics(conn.platform_user_id, accessToken);
      }

      // ── Fetch previous_follower_count for 24h growth delta ──────────────
      const { data: existing } = await supabase
        .from('platform_metrics')
        .select('previous_follower_count')
        .eq('platform_connection_id', conn.id)
        .maybeSingle();
      const prevCount = (existing?.previous_follower_count as number | null) ?? 0;
      const currentFollowers = metrics.followers;
      const followerGrowth = prevCount > 0 ? Math.max(0, currentFollowers - prevCount) : 0;

      // ── Compute Display Score (bigint: additive raw points) ──────────────
      const displayScore = computeDisplayScore(
        conn.platform,
        currentFollowers,
        metrics.liveViewers,
        followerGrowth,
        conn.platform === 'spotify' ? (metrics.savedTracks ?? 0) : (metrics.recentPostViews ?? 0),
        conn.platform === 'spotify' ? (metrics.savedAlbums ?? 0) : (metrics.recentPostReposts ?? 0),
        metrics.recentPostLikes ?? 0,
      );

      // ── Compute Heat Score (baseline 0 — only active boost deltas) ──────
      const now = new Date().toISOString();
      const { data: activeBoosts } = await supabase
        .from('active_boosts')
        .select('heat_score_delta')
        .eq('target_user_id', conn.user_id)
        .eq('is_cancelled', false)
        .or(`expires_at.is.null,expires_at.gt.${now}`);

      const boostSum = (activeBoosts ?? []).reduce(
        (acc: number, b: { heat_score_delta: number | null }) =>
          acc + (typeof b.heat_score_delta === 'number' ? b.heat_score_delta : 0),
        0,
      );

      // heat_score baseline is 0 — only boosts move it
      const heatScore = Math.min(100, Math.max(0, boostSum));

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
            display_score: displayScore,
            heat_score: heatScore,
            previous_follower_count: currentFollowers,
            recent_post_views: conn.platform === 'spotify'
              ? (metrics.savedTracks ?? null)
              : (metrics.recentPostViews ?? null),
            recent_post_reposts: conn.platform === 'spotify'
              ? (metrics.savedAlbums ?? null)
              : (metrics.recentPostReposts ?? null),
            recent_post_likes: conn.platform === 'spotify' ? null : (metrics.recentPostLikes ?? null),
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

      processedUserIds.add(conn.user_id);
      results.push({ user_id: conn.user_id, platform: conn.platform, success: true });
    } catch (err) {
      const msg = err instanceof Error ? err.message : String(err);
      console.error(`[sync-platform-metrics] ${conn.platform}/${conn.user_id} failed:`, msg);
      results.push({ user_id: conn.user_id, platform: conn.platform, success: false, error: msg });
    }
  }

  // ── Write composite score_history entry per unique user ─────────────────
  for (const userId of processedUserIds) {
    try {
      const { data: allMetrics } = await supabase
        .from('platform_metrics')
        .select('display_score')
        .eq('user_id', userId);
      const composite = (allMetrics ?? []).reduce(
        (s: number, m: { display_score: number | null }) => s + Number(m.display_score ?? 0),
        0,
      );
      await supabase.from('score_history').insert({ user_id: userId, composite_score: composite });
    } catch (e) {
      console.error(`[sync-platform-metrics] score_history insert failed for ${userId}:`, e);
    }
  }

  const synced = results.filter((r) => r.success).length;
  return json({ synced, total: results.length, results }, 200, corsHeaders);
});

// ─────────────────────────────────────────────────────────────────────────────
// Display Score Formula (bigint — raw points, platform-specific)
// ─────────────────────────────────────────────────────────────────────────────

function computeDisplayScore(
  platform: string,
  followers: number,
  liveViewers: number,
  followerGrowth: number,
  xPostViews: number = 0,
  xPostReposts: number = 0,
  xPostLikes: number = 0,
): number {
  if (platform === 'x') {
    // X: followers×1 + live_viewers×10 + post_views×0.1 + post_reposts×3 + post_likes×1
    return Math.floor(
      followers * 1 +
      liveViewers * 10 +
      Math.round(xPostViews * 0.1) +
      xPostReposts * 3 +
      xPostLikes * 1,
    );
  }
  if (platform === 'spotify') {
    // Spotify: followers×1 + savedTracks×3 + savedAlbums×3
    // xPostViews param carries savedTracks; xPostReposts carries savedAlbums
    return Math.floor(followers * 1 + xPostViews * 3 + xPostReposts * 3);
  }
  // YouTube: subscribers×1 + live_viewers×10 + 24h_growth×5
  // Twitch:  followers×1  + live_viewers×10 + 24h_growth×5
  return Math.floor(followers * 1 + liveViewers * 10 + followerGrowth * 5);
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
// X (Twitter) API
// ─────────────────────────────────────────────────────────────────────────────

async function fetchXMetrics(
  xUserId: string,
  accessToken: string,
): Promise<PlatformMetrics> {
  const bearerToken = Deno.env.get('X_BEARER_TOKEN') ?? '';
  // Use user's access token for endpoints requiring user context (non_public_metrics)
  const userAuthHeaders = { Authorization: `Bearer ${accessToken}` };
  // Use app bearer token for public endpoints
  const appBearerHeaders = { Authorization: `Bearer ${bearerToken}` };

  // 1. Get follower count from user public_metrics (app bearer token)
  const profileRes = await fetch(
    `https://api.twitter.com/2/users/${xUserId}?user.fields=public_metrics`,
    { headers: appBearerHeaders },
  );
  if (!profileRes.ok) {
    if (profileRes.status === 429) {
      console.warn('[sync-platform-metrics] X rate limited on profile endpoint — skipping');
      throw new Error('X API rate limited');
    }
    throw new Error(`X profile API ${profileRes.status}`);
  }
  const profileData = await profileRes.json();
  const publicMetrics = profileData.data?.public_metrics;
  const followers = (publicMetrics?.followers_count as number) ?? 0;

  // 2. Get most recent tweet metrics (user auth for non_public_metrics / impression_count)
  let recentPostViews = 0;
  let recentPostReposts = 0;
  let recentPostLikes = 0;
  try {
    const tweetsRes = await fetch(
      `https://api.twitter.com/2/users/${xUserId}/tweets?max_results=5&tweet.fields=public_metrics,non_public_metrics&exclude=replies,retweets`,
      { headers: userAuthHeaders },
    );
    if (tweetsRes.ok) {
      const tweetsData = await tweetsRes.json();
      const tweet = tweetsData.data?.[0];
      if (tweet) {
        recentPostReposts = (tweet.public_metrics?.retweet_count as number) ?? 0;
        recentPostLikes = (tweet.public_metrics?.like_count as number) ?? 0;
        // impression_count is in non_public_metrics (user auth, own tweets only)
        // falls back to 0 if not available on current API access tier
        recentPostViews =
          (tweet.non_public_metrics?.impression_count as number) ??
          (tweet.public_metrics?.impression_count as number) ??
          0;
      }
    } else if (tweetsRes.status === 429) {
      console.warn('[sync-platform-metrics] X rate limited on tweets endpoint — skipping post metrics');
    } else {
      console.warn(`[sync-platform-metrics] X tweets API ${tweetsRes.status} — skipping post metrics`);
    }
  } catch (e) {
    console.warn('[sync-platform-metrics] X tweets fetch failed (non-fatal):', e);
  }

  // 3. Check for live Spaces (app bearer token, by creator user ID)
  let isLive = false;
  let liveViewers = 0;
  try {
    const spacesRes = await fetch(
      `https://api.twitter.com/2/spaces/by/creator_ids?user_ids=${xUserId}&space.fields=participant_count,state`,
      { headers: appBearerHeaders },
    );
    if (spacesRes.ok) {
      const spacesData = await spacesRes.json();
      const liveSpaces = ((spacesData.data ?? []) as Array<{ state: string; participant_count?: number }>)
        .filter((s) => s.state === 'live');
      if (liveSpaces.length > 0) {
        isLive = true;
        liveViewers = liveSpaces[0].participant_count ?? 0;
      }
    } else if (spacesRes.status === 429) {
      console.warn('[sync-platform-metrics] X rate limited on spaces endpoint — skipping live check');
    } else {
      // Spaces API may require elevated access; treat as non-live gracefully
      console.warn(`[sync-platform-metrics] X spaces API ${spacesRes.status} — treating as not live`);
    }
  } catch (e) {
    console.warn('[sync-platform-metrics] X spaces fetch failed (non-fatal):', e);
  }

  return {
    isLive,
    liveViewers,
    followers,
    recentPostViews,
    recentPostReposts,
    recentPostLikes,
    raw: { profile: profileData },
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Spotify API
// ─────────────────────────────────────────────────────────────────────────────

async function fetchSpotifyMetrics(
  _spotifyUserId: string,
  accessToken: string,
): Promise<PlatformMetrics> {
  const headers = { Authorization: `Bearer ${accessToken}` };

  // 1. Follower count from /me
  const meRes = await fetch('https://api.spotify.com/v1/me', { headers });
  if (meRes.status === 429) {
    console.warn('[sync-platform-metrics] Spotify rate limited on /me — skipping');
    throw new Error('Spotify API rate limited');
  }
  if (meRes.status === 401) throw new Error('Spotify 401 — token expired');
  if (!meRes.ok) throw new Error(`Spotify /me API ${meRes.status}`);
  const meData = await meRes.json();
  const followers = (meData.followers?.total as number) ?? 0;

  // 2. Saved tracks total (read first page, limit=1, grab total only)
  let savedTracks = 0;
  try {
    const tracksRes = await fetch(
      'https://api.spotify.com/v1/me/tracks?limit=1',
      { headers },
    );
    if (tracksRes.ok) {
      const tracksData = await tracksRes.json();
      savedTracks = (tracksData.total as number) ?? 0;
    } else if (tracksRes.status === 429) {
      console.warn('[sync-platform-metrics] Spotify rate limited on /me/tracks — skipping saved tracks');
    } else {
      console.warn(`[sync-platform-metrics] Spotify /me/tracks ${tracksRes.status} — skipping saved tracks`);
    }
  } catch (e) {
    console.warn('[sync-platform-metrics] Spotify tracks fetch failed (non-fatal):', e);
  }

  // 3. Saved albums total (read first page, limit=1, grab total only)
  let savedAlbums = 0;
  try {
    const albumsRes = await fetch(
      'https://api.spotify.com/v1/me/albums?limit=1',
      { headers },
    );
    if (albumsRes.ok) {
      const albumsData = await albumsRes.json();
      savedAlbums = (albumsData.total as number) ?? 0;
    } else if (albumsRes.status === 429) {
      console.warn('[sync-platform-metrics] Spotify rate limited on /me/albums — skipping saved albums');
    } else {
      console.warn(`[sync-platform-metrics] Spotify /me/albums ${albumsRes.status} — skipping saved albums`);
    }
  } catch (e) {
    console.warn('[sync-platform-metrics] Spotify albums fetch failed (non-fatal):', e);
  }

  return {
    isLive: false,
    liveViewers: 0,
    followers,
    savedTracks,
    savedAlbums,
    raw: { me: meData },
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
    } else if (platform === 'twitch') {
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
    } else if (platform === 'x') {
      // x — confidential client uses Basic auth
      const clientId = Deno.env.get('X_CLIENT_ID') ?? '';
      const clientSecret = Deno.env.get('X_CLIENT_SECRET') ?? '';
      const credentials = btoa(`${clientId}:${clientSecret}`);
      const res = await fetch('https://api.twitter.com/2/oauth2/token', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          Authorization: `Basic ${credentials}`,
        },
        body: new URLSearchParams({
          grant_type: 'refresh_token',
          refresh_token: refreshToken,
          client_id: clientId,
        }),
      });
      if (!res.ok) return null;
      return res.json();
    } else {
      // spotify — Basic auth with client_id:client_secret
      const clientId = Deno.env.get('SPOTIFY_CLIENT_ID') ?? '';
      const clientSecret = Deno.env.get('SPOTIFY_CLIENT_SECRET') ?? '';
      const credentials = btoa(`${clientId}:${clientSecret}`);
      const res = await fetch('https://accounts.spotify.com/api/token', {
        method: 'POST',
        headers: {
          'Content-Type': 'application/x-www-form-urlencoded',
          Authorization: `Basic ${credentials}`,
        },
        body: new URLSearchParams({
          grant_type: 'refresh_token',
          refresh_token: refreshToken,
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
