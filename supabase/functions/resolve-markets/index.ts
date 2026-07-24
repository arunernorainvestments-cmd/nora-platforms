// supabase/functions/resolve-markets/index.ts
// Triggered by pg_cron every 15 minutes.
// Resolves all markets whose end_at has passed and status is still 'open'.
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';

// The untyped-schema client shape createClient() actually returns; bare
// `ReturnType<typeof createClient>` resolves to different generics under
// supabase-js v2.5x types and rejects the real instance.
// deno-lint-ignore no-explicit-any
type Db = SupabaseClient<any, any, any, any, any>;

// ─────────────────────────────────────────────────────────────────────────────
// Phase 7: fire-and-forget challenge evaluation hook
// ─────────────────────────────────────────────────────────────────────────────

async function fireChallenge(
  userId: string,
  event: string,
  metadata: Record<string, unknown> = {},
): Promise<void> {
  const fnUrl = `${Deno.env.get('SUPABASE_URL')}/functions/v1/evaluate-challenges`;
  try {
    await fetch(fnUrl, {
      method: 'POST',
      headers: {
        Authorization: `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({ user_id: userId, event, metadata }),
    });
  } catch (e) {
    console.error(`fireChallenge(${event}) failed for ${userId}:`, e);
  }
}

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': 'https://noraplatforms.com',
  'Access-Control-Allow-Headers': 'content-type, authorization',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

interface Market {
  id: string;
  creator_id: string;
  opened_by: string | null;
  title: string;
  opening_resolution_score: number | null;
  end_at: string;
  resolution_type:
    | 'display_score'
    | 'battle_outcome'
    | 'card_ascension_time'
    | 'collection_sellout_date'
    | 'spotlight_champion';
  battle_match_id: string | null;
}

// Card-centric market types (Collections spec N5) — token-settled, resolved from
// an internal-table oracle (card_market_outcome, mig 174), reusing the existing
// pool payout. Never social-API-dependent.
const CARD_CENTRIC_TYPES = [
  'card_ascension_time',
  'collection_sellout_date',
  'spotlight_champion',
] as const;

interface Bet {
  id: string;
  user_id: string;
  position: string; // 'yes' | 'no'
  amount: number;
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }

  // Verify shared secret to prevent unauthorized triggering
  const cronSecret = Deno.env.get('CRON_SECRET') ?? '';
  if (cronSecret && req.headers.get('x-cron-secret') !== cronSecret) {
    return new Response(JSON.stringify({ error: 'Unauthorized' }), {
      status: 401,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

  if (!supabaseUrl || !serviceRoleKey) {
    console.error('Missing SUPABASE_URL or SUPABASE_SERVICE_ROLE_KEY');
    return new Response(JSON.stringify({ error: 'Server misconfigured' }), {
      status: 500,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }

  const db = createClient(supabaseUrl, serviceRoleKey);

  try {
    // Query all markets where end_at <= now() and status = 'open'
    // Note: uses end_at (the original close timestamp) rather than a separate
    // closes_at column, since migration 009 adds resolution columns only.
    const { data: markets, error: marketsError } = await db
      .from('markets')
      .select('id, creator_id, opened_by, title, opening_resolution_score, end_at, resolution_type, battle_match_id')
      .lte('end_at', new Date().toISOString())
      .eq('status', 'open');

    if (marketsError) throw marketsError;

    if (!markets || markets.length === 0) {
      console.log('No markets to resolve');
      return new Response(JSON.stringify({ resolved: 0 }), {
        status: 200,
        headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
      });
    }

    console.log(`Found ${markets.length} market(s) to resolve`);

    let resolvedCount = 0;
    const errors: string[] = [];

    for (const market of markets) {
      try {
        await resolveMarket(db, market as Market);
        resolvedCount++;
      } catch (err) {
        const msg = `Market ${market.id}: ${err instanceof Error ? err.message : String(err)}`;
        console.error(msg);
        errors.push(msg);
      }
    }

    return new Response(JSON.stringify({ resolved: resolvedCount, errors }), {
      status: 200,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  } catch (err) {
    console.error('resolve-markets top-level error:', err);
    return new Response(JSON.stringify({ error: 'Internal server error' }), {
      status: 500,
      headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
    });
  }
});

async function resolveMarket(
  db: Db,
  market: Market,
): Promise<void> {
  console.log(`Resolving market ${market.id} (creator: ${market.creator_id}, type: ${market.resolution_type})`);

  // Battle outcome markets are settled by process_battle_turn() immediately on
  // match resolve. This cron path is the 24-hour safety net (e.g. if the turn
  // processor failed to settle). Skip if the match is still in progress.
  if (market.resolution_type === 'battle_outcome') {
    await resolveBattleOutcomeMarket(db, market);
    return;
  }

  // Card-centric markets (N5): the internal-table oracle decides yes/no/refund;
  // settlement reuses the token pool payout below.
  if ((CARD_CENTRIC_TYPES as readonly string[]).includes(market.resolution_type)) {
    await resolveCardCentricMarket(db, market);
    return;
  }

  // 1. Fetch creator's current composite display_score (sum across all platforms).
  const { data: allMetrics } = await db
    .from('platform_metrics')
    .select('display_score')
    .eq('user_id', market.creator_id);

  const currentScore = (allMetrics && allMetrics.length > 0)
    ? allMetrics.reduce((s: number, m: { display_score: number | null }) => s + Number(m.display_score ?? 0), 0)
    : null;

  // 2. Determine result
  let result: 'above' | 'below' | 'refund';

  if (currentScore === null || market.opening_resolution_score === null) {
    result = 'refund';
    console.log(`Market ${market.id}: missing metrics or snapshot → refund`);
  } else {
    const opening = Number(market.opening_resolution_score);
    if (currentScore > opening) result = 'above';
    else if (currentScore < opening) result = 'below';
    else result = 'refund';
    console.log(`Market ${market.id}: current=${currentScore}, opening=${opening} → ${result}`);
  }

  // 3. Fetch all active bets for this market
  const { data: bets, error: betsError } = await db
    .from('bets')
    .select('id, user_id, position, amount')
    .eq('market_id', market.id)
    .eq('status', 'active');

  if (betsError) throw betsError;

  // No bets at all → void the market silently
  if (!bets || bets.length === 0) {
    await db.from('markets').update({
      status: 'voided',
      resolution_result: 'voided',
      resolved_at: new Date().toISOString(),
      platform_fee_collected: 0,
      market_maker_fee_collected: 0,
    }).eq('id', market.id);
    console.log(`Market ${market.id}: no bets → voided`);
    return;
  }

  // If winning side has zero bets → force refund (void market)
  if (result !== 'refund') {
    const winningPosition = result === 'above' ? 'yes' : 'no';
    const hasWinningSideBets = (bets as Bet[]).some((b) => b.position === winningPosition);
    if (!hasWinningSideBets) {
      result = 'refund';
      console.log(`Market ${market.id}: no bets on winning side → refund`);
    }
  }

  // 4. Fetch creator username for notification messages
  const { data: creatorProfile } = await db
    .from('profiles')
    .select('username')
    .eq('id', market.creator_id)
    .single();
  const creatorName = creatorProfile?.username ?? 'the creator';

  if (result === 'refund') {
    await processRefund(db, market, bets as Bet[], creatorName);
  } else {
    await processPayout(db, market, bets as Bet[], result, creatorName);
  }
}

async function resolveCardCentricMarket(
  db: Db,
  market: Market,
): Promise<void> {
  // The oracle reads only internal tables (moment_chits/tier_ladder, collections,
  // arena_spotlight_assignments) — no social-API dependency (Collections spec N5).
  const { data: outcome, error: oracleErr } = await db.rpc('card_market_outcome', {
    p_market_id: market.id,
  });
  if (oracleErr) throw oracleErr;

  const { data: bets, error: betsError } = await db
    .from('bets')
    .select('id, user_id, position, amount')
    .eq('market_id', market.id)
    .eq('status', 'active');
  if (betsError) throw betsError;

  // No bets → void silently (same as the display path).
  if (!bets || bets.length === 0) {
    await db.from('markets').update({
      status: 'voided',
      resolution_result: 'voided',
      resolved_at: new Date().toISOString(),
      platform_fee_collected: 0,
      market_maker_fee_collected: 0,
    }).eq('id', market.id);
    console.log(`[resolve-markets] card market ${market.id}: no bets → voided`);
    return;
  }

  // Map the oracle to the pool payout's 'above' (YES) / 'below' (NO) result.
  let result: 'above' | 'below' | 'refund' =
    outcome === 'yes' ? 'above' : outcome === 'no' ? 'below' : 'refund';

  // If the winning side has no bets, refund (no counterparty).
  if (result !== 'refund') {
    const winningPosition = result === 'above' ? 'yes' : 'no';
    if (!(bets as Bet[]).some((b) => b.position === winningPosition)) {
      result = 'refund';
    }
  }

  const label = market.title.length > 60 ? `${market.title.slice(0, 57)}…` : market.title;
  if (result === 'refund') {
    await processRefund(db, market, bets as Bet[], label);
  } else {
    await processPayout(db, market, bets as Bet[], result, label);
  }
  console.log(`[resolve-markets] card market ${market.id} (${market.resolution_type}) → ${outcome}`);
}

async function resolveBattleOutcomeMarket(
  db: Db,
  market: Market,
): Promise<void> {
  if (!market.battle_match_id) {
    console.warn(`[resolve-markets] battle market ${market.id} has no battle_match_id — voiding`);
    await db.from('markets').update({
      status: 'voided',
      resolution_result: 'voided',
      resolved_at: new Date().toISOString(),
    }).eq('id', market.id);
    return;
  }

  // Look up the battle match to find the winner
  const { data: match, error: matchErr } = await db
    .from('battle_matches')
    .select('id, status, winner_team_number')
    .eq('id', market.battle_match_id)
    .single();

  if (matchErr || !match) {
    console.warn(`[resolve-markets] battle match ${market.battle_match_id} not found — voiding market ${market.id}`);
    await db.from('markets').update({
      status: 'voided',
      resolution_result: 'voided',
      resolved_at: new Date().toISOString(),
    }).eq('id', market.id);
    return;
  }

  // Skip — match still active; the 24h end_at window has passed but match may
  // just be slow. process_battle_turn will settle when match resolves.
  if (match.status !== 'resolved' || !match.winner_team_number) {
    console.log(`[resolve-markets] battle market ${market.id}: match not resolved yet (${match.status}) — skipping`);
    return;
  }

  const winnerPos = `team_${match.winner_team_number}`;
  const loserPos  = `team_${match.winner_team_number === 1 ? 2 : 1}`;

  const { error: distErr } = await db.rpc('distribute_match_revenue', {
    p_market_id:        market.id,
    p_battle_match_id:  market.battle_match_id,
    p_winning_position: winnerPos,
    p_losing_position:  loserPos,
  });

  if (distErr) {
    throw new Error(`distribute_match_revenue failed for market ${market.id}: ${distErr.message}`);
  }

  console.log(`[resolve-markets] battle market ${market.id} settled via cron fallback (${winnerPos} wins)`);
}

async function processRefund(
  db: Db,
  market: Market,
  bets: Bet[],
  creatorName: string,
): Promise<void> {
  console.log(`Refunding market ${market.id} — ${bets.length} bet(s)`);

  for (const bet of bets) {
    const amount = Math.floor(Number(bet.amount));

    // Credit tokens back to bettor
    const { error: creditError } = await db.rpc('increment_token_balance', {
      p_user_id: bet.user_id,
      p_amount: amount,
    });
    if (creditError) {
      console.error(`Refund credit failed for bet ${bet.id}:`, creditError);
    }

    // Record refund transaction
    await db.from('token_transactions').insert({
      user_id: bet.user_id,
      type: 'refund',
      amount,
      reference_id: bet.id,
      description: `Bet refunded — market voided`,
    });

    // Update bet status
    await db.from('bets')
      .update({ status: 'refunded', settled_at: new Date().toISOString() })
      .eq('id', bet.id);

    // Notify bettor
    await db.from('notifications').insert({
      user_id: bet.user_id,
      type: 'bet_refunded',
      title: 'Market voided',
      body: `Your bet on ${creatorName} was refunded — market voided.`,
      reference_id: market.id,
    });
  }

  // Mark market as voided
  await db.from('markets').update({
    status: 'voided',
    resolution_result: 'voided',
    resolved_at: new Date().toISOString(),
    platform_fee_collected: 0,
    market_maker_fee_collected: 0,
  }).eq('id', market.id);

  console.log(`Market ${market.id} voided, ${bets.length} bet(s) refunded`);
}

async function processPayout(
  db: Db,
  market: Market,
  bets: Bet[],
  result: 'above' | 'below',
  creatorName: string,
): Promise<void> {
  // 'above' maps to 'yes' position; 'below' maps to 'no' position
  const winningPosition = result === 'above' ? 'yes' : 'no';
  const losingPosition  = result === 'above' ? 'no'  : 'yes';

  const winningBets = bets.filter((b) => b.position === winningPosition);
  const losingBets  = bets.filter((b) => b.position === losingPosition);

  const totalWinning = winningBets.reduce((sum, b) => sum + Math.floor(Number(b.amount)), 0);
  const totalLosing  = losingBets.reduce((sum, b) => sum + Math.floor(Number(b.amount)), 0);
  const totalPool    = totalWinning + totalLosing;

  // Integer rake calculation (all percentages of losing pool, rounded down)
  const rake           = Math.floor(totalLosing * 0.10);
  const platformFee    = Math.floor(totalLosing * 0.05);
  const marketMakerFee = rake - platformFee;
  const winningPool    = totalPool - rake;

  console.log(
    `Market ${market.id}: pool=${totalPool}, winning=${totalWinning}, losing=${totalLosing}, ` +
    `rake=${rake}, platformFee=${platformFee}, mmFee=${marketMakerFee}, winningPool=${winningPool}`,
  );

  // --- Determine minority pool for contrarian badge checks ---
  const winningPoolTotal = winningBets.reduce((s, b) => s + Math.floor(Number(b.amount)), 0);
  const minorityThreshold = 0.3; // <30% of total pool = minority side
  const winnerIsMinority  = totalPool > 0 && (winningPoolTotal / totalPool) < minorityThreshold;

  // --- Distribute winnings proportionally to winning bettors ---
  for (const bet of winningBets) {
    const betAmount = Math.floor(Number(bet.amount));
    const payout = totalWinning > 0
      ? Math.floor(winningPool * (betAmount / totalWinning))
      : 0;

    const { error: creditError } = await db.rpc('increment_token_balance', {
      p_user_id: bet.user_id,
      p_amount: payout,
    });
    if (creditError) {
      console.error(`Payout credit failed for bet ${bet.id}:`, creditError);
    }

    await db.from('token_transactions').insert({
      user_id: bet.user_id,
      type: 'bet_won',
      amount: payout,
      reference_id: bet.id,
      description: `Won bet on ${creatorName}`,
    });

    await db.from('bets')
      .update({ status: 'won', settled_at: new Date().toISOString() })
      .eq('id', bet.id);

    await db.from('notifications').insert({
      user_id: bet.user_id,
      type: 'bet_won',
      title: 'You won!',
      body: `Your bet on ${creatorName} paid out — you won ${payout} tokens!`,
      reference_id: market.id,
    });

    // Phase 7 deferred: apply token_earn_rate passive bonus (badge effect)
    if (payout > 0) {
      const { data: passiveRow } = await db
        .from('user_passive_effects')
        .select('token_earn_rate')
        .eq('user_id', bet.user_id)
        .maybeSingle();
      const earnRate = (passiveRow?.token_earn_rate as number | null) ?? 0;
      if (earnRate > 0) {
        const bonus = Math.floor(payout * earnRate);
        if (bonus > 0) {
          await db.rpc('increment_token_balance', { p_user_id: bet.user_id, p_amount: bonus });
          await db.from('token_transactions').insert({
            user_id: bet.user_id,
            type: 'passive_bonus',
            amount: bonus,
            reference_id: market.id,
            description: `Badge earn rate bonus on ${creatorName}`,
          });
        }
      }
    }

    // Phase 7: challenge hooks for winners
    fireChallenge(bet.user_id, 'bet_won', { market_id: market.id }).catch(console.error);
    fireChallenge(bet.user_id, 'bet_resolved_win', { market_id: market.id }).catch(console.error);
    if (payout > 0) {
      fireChallenge(bet.user_id, 'tokens_earned', { amount: payout }).catch(console.error);
    }
    if (winnerIsMinority) {
      fireChallenge(bet.user_id, 'bet_won_minority', { market_id: market.id }).catch(console.error);
    }
  }

  // --- Record bet_lost for losing bettors (amount = 0 per spec) ---
  for (const bet of losingBets) {
    await db.from('token_transactions').insert({
      user_id: bet.user_id,
      type: 'bet_lost',
      amount: 0,
      reference_id: bet.id,
      description: `Lost bet on ${creatorName}`,
    });

    await db.from('bets')
      .update({ status: 'lost', settled_at: new Date().toISOString() })
      .eq('id', bet.id);

    await db.from('notifications').insert({
      user_id: bet.user_id,
      type: 'bet_lost',
      title: 'Bet lost',
      body: `Your bet on ${creatorName} did not pay out.`,
      reference_id: market.id,
    });

    // Phase 7: challenge hook for losers
    fireChallenge(bet.user_id, 'bet_lost', { market_id: market.id }).catch(console.error);
  }

  // --- Phase 7: market_resolution_top_stake for the single largest winner ---
  if (winningBets.length > 0) {
    const topWinner = winningBets.reduce((top, b) =>
      Math.floor(Number(b.amount)) > Math.floor(Number(top.amount)) ? b : top,
    );
    fireChallenge(topWinner.user_id, 'market_resolution_top_stake', {
      market_id: market.id,
      amount: Math.floor(Number(topWinner.amount)),
    }).catch(console.error);
  }

  // --- Credit Market Maker fee ---
  if (market.opened_by && marketMakerFee > 0) {
    const { error: mmCreditError } = await db.rpc('increment_token_balance', {
      p_user_id: market.opened_by,
      p_amount: marketMakerFee,
    });
    if (mmCreditError) {
      console.error(`MM fee credit failed for market ${market.id}:`, mmCreditError);
    }

    await db.from('token_transactions').insert({
      user_id: market.opened_by,
      type: 'promoted',
      amount: marketMakerFee,
      reference_id: market.id,
      description: `Market Maker fee — market resolved`,
    });

    await db.from('notifications').insert({
      user_id: market.opened_by,
      type: 'market_resolved',
      title: 'Market resolved',
      body: `Your market on ${creatorName} resolved. You earned ${marketMakerFee} tokens.`,
      reference_id: market.id,
    });
  }

  // --- Update market to resolved ---
  await db.from('markets').update({
    status: 'resolved',
    resolution_result: result,
    resolved_at: new Date().toISOString(),
    platform_fee_collected: platformFee,
    market_maker_fee_collected: marketMakerFee,
  }).eq('id', market.id);

  console.log(`Market ${market.id} resolved as '${result}'`);
}
