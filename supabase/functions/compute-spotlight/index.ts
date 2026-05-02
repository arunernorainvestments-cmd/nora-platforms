// compute-spotlight — Phase D rewrite
//
// Returns dual rankings as JSON: { champions, top_movers }
//
// Arena Champions: read from arena_spotlight_assignments for the current week
//   (locked Monday 00:00 UTC by arena_monday_rollover).
//   If no assignments exist yet (early weeks), champions is an empty array.
//
// Top Movers: trailing 7-day composite Display Score growth from score_history.
//   Computed dynamically on every call (no fallback cache — add Upstash if needed).
//   Excludes test accounts. Handles new creators with no 7-day history.
//
// LEGACY BEHAVIOR REMOVED: no longer writes to spotlight_scores or calls
// recompute_spotlight_tiers(). The old token-activity ranking is fully retired.
// spotlight_scores table is preserved but no longer updated by this function.

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

interface ChampionEntry {
  user_id: string;
  username: string | null;
  display_name: string | null;
  avatar_url: string | null;
  display_score: number;
  heat_score: number;
  slot: number;
}

interface TopMoverEntry {
  user_id: string;
  username: string | null;
  display_name: string | null;
  avatar_url: string | null;
  display_score: number;
  weekly_growth_pct: number;
}

interface SpotlightResponse {
  champions: ChampionEntry[];
  top_movers: TopMoverEntry[];
  computed_at: string;
  week_start: string;
}

function json(data: unknown, status = 200): Response {
  return new Response(JSON.stringify(data), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}

function getThisMonday(now: Date = new Date()): string {
  const utcDay = now.getUTCDay(); // 0=Sunday
  const daysFromMonday = utcDay === 0 ? 6 : utcDay - 1;
  const monday = new Date(now);
  monday.setUTCDate(monday.getUTCDate() - daysFromMonday);
  monday.setUTCHours(0, 0, 0, 0);
  return monday.toISOString().split('T')[0]; // YYYY-MM-DD
}

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method !== 'POST' && req.method !== 'GET') {
    return json({ error: 'Method not allowed' }, 405);
  }

  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    { auth: { persistSession: false } },
  );

  const includeTestAccounts = Deno.env.get('INCLUDE_TEST_ACCOUNTS') === 'true';
  const now = new Date();
  const weekStart = getThisMonday(now);

  try {
    // ── 1. Arena Champions ────────────────────────────────────────────────────
    const { data: assignment, error: assignmentErr } = await supabase
      .from('arena_spotlight_assignments')
      .select('slot_1_user_id, slot_2_user_id, slot_3_user_id, slot_4_user_id, slot_5_user_id')
      .eq('week_start', weekStart)
      .maybeSingle();

    if (assignmentErr) throw new Error(`Fetching spotlight assignments: ${assignmentErr.message}`);

    const champions: ChampionEntry[] = [];

    if (assignment) {
      const slotEntries: Array<{ slot: number; user_id: string | null }> = [
        { slot: 1, user_id: assignment.slot_1_user_id },
        { slot: 2, user_id: assignment.slot_2_user_id },
        { slot: 3, user_id: assignment.slot_3_user_id },
        { slot: 4, user_id: assignment.slot_4_user_id },
        { slot: 5, user_id: assignment.slot_5_user_id },
      ];

      const slotIds = slotEntries.map((s) => s.user_id).filter(Boolean) as string[];

      if (slotIds.length > 0) {
        const [profilesResult, metricsResult] = await Promise.all([
          supabase
            .from('profiles')
            .select('id, username, display_name, avatar_url')
            .in('id', slotIds),
          supabase
            .from('platform_metrics')
            .select('user_id, display_score, heat_score')
            .in('user_id', slotIds),
        ]);

        const profileMap = new Map<string, { username: string | null; display_name: string | null; avatar_url: string | null }>();
        for (const p of profilesResult.data ?? []) {
          profileMap.set(p.id as string, {
            username: p.username as string | null,
            display_name: p.display_name as string | null,
            avatar_url: p.avatar_url as string | null,
          });
        }

        // Sum display_score per user (additive across platform rows)
        const displayScoreMap = new Map<string, number>();
        const heatScoreMap    = new Map<string, number>();
        for (const m of metricsResult.data ?? []) {
          const uid = m.user_id as string;
          displayScoreMap.set(uid, (displayScoreMap.get(uid) ?? 0) + ((m.display_score as number | null) ?? 0));
          heatScoreMap.set(uid, Math.max(heatScoreMap.get(uid) ?? 0, (m.heat_score as number | null) ?? 0));
        }

        for (const { slot, user_id } of slotEntries) {
          if (!user_id) continue;
          const profile = profileMap.get(user_id);
          champions.push({
            user_id,
            username:       profile?.username     ?? null,
            display_name:   profile?.display_name ?? null,
            avatar_url:     profile?.avatar_url   ?? null,
            display_score:  displayScoreMap.get(user_id) ?? 0,
            heat_score:     heatScoreMap.get(user_id)    ?? 0,
            slot,
          });
        }
      }
    }

    // ── 2. Top Movers ─────────────────────────────────────────────────────────
    // Get eligible market makers
    const creatorsQuery = supabase
      .from('profiles')
      .select('id, username, display_name, avatar_url')
      .eq('is_market_maker', true)
      .eq('pending_opt_out', false);

    const { data: creators, error: creatorsErr } = includeTestAccounts
      ? await creatorsQuery
      : await creatorsQuery.eq('is_test_account', false);

    if (creatorsErr) throw new Error(`Fetching creators: ${creatorsErr.message}`);
    const creatorIds = (creators ?? []).map((c) => c.id as string);

    const topMovers: TopMoverEntry[] = [];

    if (creatorIds.length > 0) {
      const sevenDaysAgo = new Date(now.getTime() - 7 * 24 * 60 * 60 * 1000).toISOString();

      // Most recent score_history per creator (proxy for current display_score)
      const { data: recentScores, error: recentErr } = await supabase
        .from('score_history')
        .select('user_id, composite_score, recorded_at')
        .in('user_id', creatorIds)
        .order('recorded_at', { ascending: false });

      if (recentErr) throw new Error(`Fetching recent scores: ${recentErr.message}`);

      // Oldest score within the trailing 7-day window per creator
      const { data: oldScores, error: oldErr } = await supabase
        .from('score_history')
        .select('user_id, composite_score, recorded_at')
        .in('user_id', creatorIds)
        .lte('recorded_at', sevenDaysAgo)
        .order('recorded_at', { ascending: false });

      if (oldErr) throw new Error(`Fetching historical scores: ${oldErr.message}`);

      // Build maps: most-recent score per user
      const recentMap = new Map<string, number>();
      for (const row of recentScores ?? []) {
        const uid = row.user_id as string;
        if (!recentMap.has(uid)) {
          recentMap.set(uid, (row.composite_score as number | null) ?? 0);
        }
      }

      // Most-recent row at-or-before 7 days ago per user
      const oldMap = new Map<string, number>();
      for (const row of oldScores ?? []) {
        const uid = row.user_id as string;
        if (!oldMap.has(uid)) {
          oldMap.set(uid, (row.composite_score as number | null) ?? 0);
        }
      }

      const profileLookup = new Map<string, { username: string | null; display_name: string | null; avatar_url: string | null }>();
      for (const c of creators ?? []) {
        profileLookup.set(c.id as string, {
          username:     c.username     as string | null,
          display_name: c.display_name as string | null,
          avatar_url:   c.avatar_url   as string | null,
        });
      }

      type MoverCandidate = {
        user_id: string;
        displayScore: number;
        growthPct: number;
      };

      const candidates: MoverCandidate[] = [];
      for (const uid of creatorIds) {
        const current = recentMap.get(uid);
        if (current === undefined) continue; // no score history at all

        const past = oldMap.get(uid);
        if (past === undefined || past === 0) continue; // no baseline to compare against

        const growthPct = ((current - past) / past) * 100;
        if (growthPct <= 0) continue; // only surface actual growth

        candidates.push({ user_id: uid, displayScore: current, growthPct });
      }

      candidates.sort((a, b) => b.growthPct - a.growthPct);

      for (const c of candidates.slice(0, 5)) {
        const profile = profileLookup.get(c.user_id);
        topMovers.push({
          user_id:          c.user_id,
          username:         profile?.username     ?? null,
          display_name:     profile?.display_name ?? null,
          avatar_url:       profile?.avatar_url   ?? null,
          display_score:    c.displayScore,
          weekly_growth_pct: Math.round(c.growthPct * 10) / 10,
        });
      }
    }

    const result: SpotlightResponse = {
      champions,
      top_movers: topMovers,
      computed_at: now.toISOString(),
      week_start: weekStart,
    };

    return json(result, 200);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error('[compute-spotlight]', message);
    return json({ error: message }, 500);
  }
});
