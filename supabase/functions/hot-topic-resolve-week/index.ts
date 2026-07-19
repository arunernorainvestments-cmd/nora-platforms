// supabase/functions/hot-topic-resolve-week/index.ts
// Runs Friday 8 PM ET (Saturday 00:00 UTC) via pg_cron. Also callable manually.
// Finalizes weekly standings and resolves all pending weekly bets.
import { serve } from 'https://deno.land/std@0.177.0/http/server.ts';
import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': 'https://noraplatforms.com',
  'Access-Control-Allow-Headers': 'content-type, authorization',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

function jsonResponse(body: unknown, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}

function getIsoWeekId(date: Date): string {
  const d = new Date(Date.UTC(date.getUTCFullYear(), date.getUTCMonth(), date.getUTCDate()));
  const dayNum = d.getUTCDay() || 7;
  d.setUTCDate(d.getUTCDate() + 4 - dayNum);
  const yearStart = new Date(Date.UTC(d.getUTCFullYear(), 0, 1));
  const weekNum = Math.ceil((((d.getTime() - yearStart.getTime()) / 86400000) + 1) / 7);
  return `${d.getUTCFullYear()}-${weekNum.toString().padStart(2, '0')}`;
}

interface WeeklyScore {
  id: string;
  celeb_id: string;
  points: number;
  rank: number | null;
  celebs: { name: string } | null;
}

interface WeeklyBet {
  id: string;
  user_id: string;
  weekly_bet_type: string;
  celeb_id: string | null;
  tokens_wagered: number;
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });

  const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  if (!supabaseUrl || !serviceRoleKey) {
    return jsonResponse({ error: 'Server misconfigured' }, 500);
  }

  const db = createClient(supabaseUrl, serviceRoleKey);
  const weekId = getIsoWeekId(new Date());

  // ── Fetch final standings ────────────────────────────────────────────────────
  const { data: scores, error: scoresError } = await db
    .from('celeb_weekly_scores')
    .select('id, celeb_id, points, rank, celebs(name)')
    .eq('week_id', weekId)
    .order('points', { ascending: false });

  if (scoresError || !scores || scores.length === 0) {
    return jsonResponse({ error: 'No scores found for current week', detail: scoresError?.message }, 500);
  }

  // The embedded celebs(name) join defeats supabase-js row inference — go
  // through unknown once, then work with the typed rows.
  const ranked = scores as unknown as WeeklyScore[];

  // Write final ranks
  for (let i = 0; i < ranked.length; i++) {
    await db
      .from('celeb_weekly_scores')
      .update({ rank: i + 1 })
      .eq('id', ranked[i].id);
  }

  // Determine winners
  const personOfWeek = ranked[0];
  const bigBoo = ranked[ranked.length - 1];

  // Top Riser: largest cumulative positive delta from celeb_score_history this week
  const { data: historyData } = await db
    .from('celeb_score_history')
    .select('celeb_id, delta')
    .eq('week_id', weekId)
    .gt('delta', 0);

  const riserTotals: Record<string, number> = {};
  for (const row of (historyData ?? []) as Array<{ celeb_id: string; delta: number }>) {
    riserTotals[row.celeb_id] = (riserTotals[row.celeb_id] ?? 0) + row.delta;
  }

  let topRiserCelebId: string | null = null;
  let topRiserTotal = 0;
  for (const [celebId, total] of Object.entries(riserTotals)) {
    if (total > topRiserTotal) {
      topRiserTotal = total;
      topRiserCelebId = celebId;
    }
  }

  // Top 5 celeb IDs (by final rank)
  const top5CelebIds = new Set(ranked.slice(0, 5).map((s) => s.celeb_id));

  // ── Fetch all pending weekly bets ────────────────────────────────────────────
  const { data: bets } = await db
    .from('weekly_bets')
    .select('id, user_id, weekly_bet_type, celeb_id, tokens_wagered')
    .eq('week_id', weekId)
    .eq('bet_category', 'weekly')
    .eq('status', 'pending');

  if (!bets || bets.length === 0) {
    return jsonResponse({
      week_id: weekId,
      person_of_week: personOfWeek.celebs?.name ?? personOfWeek.celeb_id,
      big_boo: bigBoo.celebs?.name ?? bigBoo.celeb_id,
      top_riser: topRiserCelebId,
      bets_resolved: 0,
    });
  }

  // ── Resolve weekly bets ──────────────────────────────────────────────────────
  // Group by bet_type
  const betsByType: Record<string, WeeklyBet[]> = {};
  for (const bet of bets as WeeklyBet[]) {
    if (!betsByType[bet.weekly_bet_type]) betsByType[bet.weekly_bet_type] = [];
    betsByType[bet.weekly_bet_type].push(bet);
  }

  let totalResolved = 0;
  let totalPaidOut = 0;

  for (const [betType, typeBets] of Object.entries(betsByType)) {
    const totalPool = typeBets.reduce((sum, b) => sum + b.tokens_wagered, 0);
    const prizePool = Math.floor(totalPool * 0.9);

    const winners = typeBets.filter((bet) => {
      switch (betType) {
        case 'person_of_week':
          return bet.celeb_id === personOfWeek.celeb_id;
        case 'big_boo':
          return bet.celeb_id === bigBoo.celeb_id;
        case 'top_riser':
          return topRiserCelebId !== null && bet.celeb_id === topRiserCelebId;
        case 'top_5':
          return bet.celeb_id !== null && top5CelebIds.has(bet.celeb_id);
        default:
          return false;
      }
    });

    const winnerCount = winners.length;
    const payoutPerWinner = winnerCount > 0 ? Math.floor(prizePool / winnerCount) : 0;

    for (const bet of typeBets) {
      const isWinner = winners.some((w) => w.id === bet.id);
      const payout = isWinner ? payoutPerWinner : 0;

      if (isWinner && payout > 0) {
        await db.rpc('increment_token_balance', { p_user_id: bet.user_id, p_amount: payout });
        await db.from('token_transactions').insert({
          user_id: bet.user_id,
          type: 'bet_won',
          amount: payout,
          reference_id: bet.id,
          description: `Won Hot Topic weekly bet (${betType})`,
        });
        totalPaidOut += payout;
      } else {
        await db.from('token_transactions').insert({
          user_id: bet.user_id,
          type: 'bet_lost',
          amount: 0,
          reference_id: bet.id,
          description: `Lost Hot Topic weekly bet (${betType})`,
        });
      }

      await db
        .from('weekly_bets')
        .update({ status: isWinner ? 'won' : 'lost', payout })
        .eq('id', bet.id);

      totalResolved++;
    }
  }

  return jsonResponse({
    week_id: weekId,
    person_of_week: personOfWeek.celebs?.name ?? personOfWeek.celeb_id,
    big_boo: bigBoo.celebs?.name ?? bigBoo.celeb_id,
    top_riser: topRiserCelebId,
    bets_resolved: totalResolved,
    total_paid_out: totalPaidOut,
  });
});
