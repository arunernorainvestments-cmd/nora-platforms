// supabase/functions/chit-ascension/index.ts
// The viral upgrade — the user surface for tier ascension (mig 136/157, spec v3 §P6.2).
//
// POST {}   (sim mode honors { sim_engagement?: number } for testing)
//
// Ascension compares the CURRENT cumulative engagement of the linked post against the
// tier a chit was minted at — so the refresh must re-read the platform APIs first, or
// the user's one weekly window is spent comparing stale mint-time counts against
// themselves. Flow:
//   1. cooldown pre-check (≤ once / 7 days per user — protects the social APIs) BEFORE
//      any external call; a refused refresh must cost nothing.
//   2. re-read live engagement per active minted moment through the SAME ownership-
//      checked readers as moment-ingest (_shared/platform_meta.ts, Hard Rule 37);
//      monotonic write (GREATEST — engagement is cumulative, an API hiccup never
//      de-ranks). Unreadable sources (rate limit HR8, expired token, deleted post)
//      are logged and skipped: last-verified tier stands.
//   3. chit_ascension_refresh (service-only since mig 157): one-directional tier-ups,
//      jump >= 3 → manual review queue, listed chits frozen. Returns per-chit detail.
//
// Sim per governance: MINT_INGEST_MODE=sim skips external APIs and takes the moment's
// stored count (or sim_engagement) — the same flag moment-ingest keys off, since this
// IS the ingest re-read. Deployed --no-verify-jwt (ES256); auth via auth.getUser().

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { fetchSourceMeta, type Connection } from '../_shared/platform_meta.ts';
import type { Platform } from '../_shared/source_urls.ts';

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

const COOLDOWN_MS = 7 * 24 * 60 * 60 * 1000;

interface MomentRow {
  id: string;
  source_platform: Platform | null;
  source_external_id: string | null;
  engagement_count: number;
  minted_chit_id: string;
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { status: 200, headers: corsHeaders });
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405);

  const authHeader = req.headers.get('Authorization');
  if (!authHeader?.startsWith('Bearer ')) return json({ error: 'Unauthorized' }, 401);
  const anon = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_ANON_KEY')!);
  const { data: { user }, error: authError } = await anon.auth.getUser(authHeader.replace('Bearer ', ''));
  if (authError || !user) return json({ error: 'Unauthorized' }, 401);

  let body: { sim_engagement?: number } = {};
  try { body = await req.json(); } catch { /* empty body is fine */ }

  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);

  // ── 1. cooldown pre-check: refuse before any platform API is touched ───────────
  const { data: lastLog } = await db.from('chit_ascension_log')
    .select('refreshed_at').eq('user_id', user.id)
    .order('refreshed_at', { ascending: false }).limit(1).maybeSingle();
  if (lastLog) {
    const nextAt = new Date(new Date(lastLog.refreshed_at).getTime() + COOLDOWN_MS);
    if (nextAt.getTime() > Date.now()) {
      return json({
        error: 'ascension_cooldown',
        detail: 'Ascension refresh is available once per 7 days',
        next_refresh_at: nextAt.toISOString(),
      }, 429);
    }
  }

  // ── 2. re-read live engagement for every active minted moment ──────────────────
  const { data: moments } = await db.from('moments')
    .select('id, source_platform, source_external_id, engagement_count, minted_chit_id')
    .eq('owner_user_id', user.id)
    .eq('source_status', 'active')
    .not('minted_chit_id', 'is', null);
  if (!moments || moments.length === 0) {
    // Nothing ascendable — do NOT burn the weekly window on an empty refresh.
    return json({
      ascended: 0, queued_for_review: 0, ascensions: [], queued: [],
      moments_synced: 0, detail: 'No ascendable chits — mint one first',
    });
  }

  const mode = Deno.env.get('MINT_INGEST_MODE') === 'live' ? 'live' : 'sim';
  let synced = 0;
  const connections = new Map<string, Connection | null>();

  for (const m of moments as MomentRow[]) {
    let engagement: number | null = null;

    if (mode === 'sim') {
      engagement = Number.isFinite(body.sim_engagement)
        ? Math.max(0, Math.floor(body.sim_engagement!))
        : m.engagement_count;   // sim default: keep the stored count (no-op re-read)
    } else if (m.source_platform && m.source_external_id) {
      if (!connections.has(m.source_platform)) {
        const { data: conn } = await db.from('platform_connections')
          .select('id, platform_user_id, platform_username, access_token, refresh_token, token_expires_at')
          .eq('user_id', user.id).eq('platform', m.source_platform).eq('is_active', true)
          .maybeSingle();
        connections.set(m.source_platform, conn as Connection | null);
      }
      const conn = connections.get(m.source_platform);
      if (!conn) {
        console.warn(`chit-ascension: ${m.source_platform} not linked, keeping last-verified tier for moment ${m.id}`);
        continue;
      }
      const fetched = await fetchSourceMeta(db,
        { platform: m.source_platform, externalId: m.source_external_id }, conn);
      if (!fetched.ok) {
        // Hard Rule 8 on 429; deleted/unowned/expired keep the last-verified tier.
        console.warn(`chit-ascension: ${m.source_platform} re-read skipped for moment ${m.id}: ${fetched.error}`);
        continue;
      }
      engagement = fetched.meta.engagement;
    } else {
      continue;   // no source reference to re-read
    }

    // Monotonic: engagement is cumulative — never lower the stored count.
    const next = Math.max(engagement, m.engagement_count);
    const { error: updErr } = await db.from('moments')
      .update({ engagement_count: next, engagement_synced_at: new Date().toISOString() })
      .eq('id', m.id);
    if (updErr) {
      console.error(`chit-ascension: engagement update failed for moment ${m.id}: ${updErr.message}`);
      continue;
    }
    synced++;
  }

  // ── 3. run the refresh (cooldown re-checked inside — atomic backstop) ──────────
  const { data: result, error: refreshErr } = await db.rpc('chit_ascension_refresh', {
    p_user_id: user.id,
  });
  if (refreshErr) {
    if (refreshErr.message.includes('once per 7 days')) {
      return json({ error: 'ascension_cooldown', detail: refreshErr.message }, 429);
    }
    return json({ error: 'ascension_refresh_failed', detail: refreshErr.message }, 500);
  }

  return json({ ...(result as Record<string, unknown>), moments_synced: synced });
});
