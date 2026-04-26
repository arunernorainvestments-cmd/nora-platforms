import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

interface CreatorScore {
  user_id: string;
  tokens_bet: number;
  tokens_promoted: number;
  unique_bettors: number;
  last_24h_activity: number;
  score: number;
}

interface SummaryResponse {
  scored: number;
  creators: Array<{ user_id: string; score: number }>;
  computed_at: string;
}

// ─────────────────────────────────────────────────────────────────────────────
// Handler
// ─────────────────────────────────────────────────────────────────────────────

Deno.serve(async (req: Request): Promise<Response> => {
  // Only allow POST and GET (GET useful for cron pings)
  if (req.method !== 'POST' && req.method !== 'GET') {
    return json({ error: 'Method not allowed' }, 405);
  }

  // Service-role client — bypasses RLS so we can read all rows and write scores
  const supabase = createClient(
    Deno.env.get('SUPABASE_URL') ?? '',
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '',
    { auth: { persistSession: false } },
  );

  try {
    const now = new Date();
    const cutoff24h = new Date(now.getTime() - 24 * 60 * 60 * 1000).toISOString();

    // ── 1. Fetch all platform creators ───────────────────────────────────────
    // Exclude test accounts unless explicitly opted in (never true in production).
    const includeTestAccounts = Deno.env.get('INCLUDE_TEST_ACCOUNTS') === 'true';

    const creatorsQuery = supabase
      .from('profiles')
      .select('id')
      .eq('is_creator', true);

    const { data: creators, error: creatorsErr } = includeTestAccounts
      ? await creatorsQuery
      : await creatorsQuery.eq('is_test_account', false);

    if (creatorsErr) throw new Error(`Fetching creators: ${creatorsErr.message}`);
    if (!creators || creators.length === 0) {
      return json({ scored: 0, creators: [], computed_at: now.toISOString() }, 200);
    }

    const creatorIds: string[] = creators.map((c) => c.id);

    // ── 2. tokens_bet per creator ─────────────────────────────────────────────
    // token_transactions where type in ('bet_won','bet_lost') and reference_id
    // is a market belonging to a platform creator.
    // We join via markets: reference_id = markets.id → markets.creator_id
    const { data: betRows, error: betErr } = await supabase
      .from('token_transactions')
      .select('amount, reference_id, markets!inner(creator_id)')
      .in('type', ['bet_won', 'bet_lost'])
      .in('markets.creator_id', creatorIds);

    if (betErr) throw new Error(`Fetching bet transactions: ${betErr.message}`);

    // ── 3. tokens_promoted per creator ────────────────────────────────────────
    // reference_id on 'promoted' transactions points directly to the creator profile id
    const { data: promoRows, error: promoErr } = await supabase
      .from('token_transactions')
      .select('amount, reference_id')
      .eq('type', 'promoted')
      .in('reference_id', creatorIds);

    if (promoErr) throw new Error(`Fetching promo transactions: ${promoErr.message}`);

    // ── 4. unique_bettors per creator ─────────────────────────────────────────
    // Distinct user_ids who have a bet transaction on each creator's markets
    const { data: bettorRows, error: bettorErr } = await supabase
      .from('token_transactions')
      .select('user_id, reference_id, markets!inner(creator_id)')
      .in('type', ['bet_won', 'bet_lost'])
      .in('markets.creator_id', creatorIds);

    if (bettorErr) throw new Error(`Fetching bettor rows: ${bettorErr.message}`);

    // ── 5. last_24h_activity per creator ──────────────────────────────────────
    // Count of ALL token_transactions related to a creator in the last 24h.
    // Covers both bet transactions (via market join) and promotions (via reference_id).
    const { data: recentBetRows, error: recentBetErr } = await supabase
      .from('token_transactions')
      .select('reference_id, markets!inner(creator_id)')
      .in('type', ['bet_won', 'bet_lost'])
      .in('markets.creator_id', creatorIds)
      .gte('created_at', cutoff24h);

    if (recentBetErr) throw new Error(`Fetching recent bet rows: ${recentBetErr.message}`);

    const { data: recentPromoRows, error: recentPromoErr } = await supabase
      .from('token_transactions')
      .select('reference_id')
      .eq('type', 'promoted')
      .in('reference_id', creatorIds)
      .gte('created_at', cutoff24h);

    if (recentPromoErr) throw new Error(`Fetching recent promo rows: ${recentPromoErr.message}`);

    // ── 6. Aggregate into per-creator maps ───────────────────────────────────

    // tokens_bet map: creator_id → total bet tokens
    const tokensBetMap = new Map<string, number>();
    for (const row of betRows ?? []) {
      const creatorId = (row.markets as { creator_id: string }).creator_id;
      tokensBetMap.set(creatorId, (tokensBetMap.get(creatorId) ?? 0) + Math.abs(row.amount));
    }

    // tokens_promoted map: creator_id → total promoted tokens
    const tokensPromoMap = new Map<string, number>();
    for (const row of promoRows ?? []) {
      const id = row.reference_id as string;
      tokensPromoMap.set(id, (tokensPromoMap.get(id) ?? 0) + Math.abs(row.amount));
    }

    // unique_bettors map: creator_id → Set of user_ids
    const bettorSetsMap = new Map<string, Set<string>>();
    for (const row of bettorRows ?? []) {
      const creatorId = (row.markets as { creator_id: string }).creator_id;
      if (!bettorSetsMap.has(creatorId)) bettorSetsMap.set(creatorId, new Set());
      bettorSetsMap.get(creatorId)!.add(row.user_id as string);
    }

    // last_24h_activity map: creator_id → count of events
    const activity24hMap = new Map<string, number>();
    for (const row of recentBetRows ?? []) {
      const creatorId = (row.markets as { creator_id: string }).creator_id;
      activity24hMap.set(creatorId, (activity24hMap.get(creatorId) ?? 0) + 1);
    }
    for (const row of recentPromoRows ?? []) {
      const id = row.reference_id as string;
      activity24hMap.set(id, (activity24hMap.get(id) ?? 0) + 1);
    }

    // ── 7. Compute scores ────────────────────────────────────────────────────

    const scores: CreatorScore[] = creatorIds.map((id) => {
      const tokensBet      = tokensBetMap.get(id)             ?? 0;
      const tokensPromoted = tokensPromoMap.get(id)           ?? 0;
      const uniqueBettors  = bettorSetsMap.get(id)?.size      ?? 0;
      const activity24h    = activity24hMap.get(id)           ?? 0;

      const score =
        tokensBet      * 1.0  +
        tokensPromoted * 1.5  +
        uniqueBettors  * 2.0  +
        activity24h    * 1.25;

      return { user_id: id, tokens_bet: tokensBet, tokens_promoted: tokensPromoted,
               unique_bettors: uniqueBettors, last_24h_activity: activity24h, score };
    });

    // ── 8. Upsert spotlight_scores ───────────────────────────────────────────

    const upsertRows = scores.map(({ user_id, score }) => ({
      user_id,
      score,
      tier: 'listed',        // placeholder — recompute_spotlight_tiers() fixes this
      computed_at: now.toISOString(),
    }));

    const { error: upsertErr } = await supabase
      .from('spotlight_scores')
      .upsert(upsertRows, { onConflict: 'user_id' });

    if (upsertErr) throw new Error(`Upserting scores: ${upsertErr.message}`);

    // ── 9. Recompute tiers via DB function ───────────────────────────────────

    const { error: tierErr } = await supabase.rpc('recompute_spotlight_tiers');
    if (tierErr) throw new Error(`Recomputing tiers: ${tierErr.message}`);

    // ── 10. Return summary ───────────────────────────────────────────────────

    const summary: SummaryResponse = {
      scored: scores.length,
      creators: scores.map(({ user_id, score }) => ({ user_id, score })),
      computed_at: now.toISOString(),
    };

    return json(summary, 200);
  } catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    console.error('[compute-spotlight]', message);
    return json({ error: message }, 500);
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

function json(body: unknown, status: number): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { 'Content-Type': 'application/json' },
  });
}
