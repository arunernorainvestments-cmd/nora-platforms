// supabase/functions/hot-topic-fetch-and-score/index.ts
// Triggered twice daily (7 AM ET, 6 PM ET) via pg_cron.
// Fetches recent news for each active celeb, scores with Claude, updates leaderboard,
// and resolves simple bets for the completed scoring window.
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

function getScoringWindow(date: Date): string {
  const dateStr = date.toISOString().slice(0, 10);
  return date.getUTCHours() < 12 ? `${dateStr}-AM` : `${dateStr}-PM`;
}

interface Celeb {
  id: string;
  name: string;
  aliases: string[];
  category: string | null;
}

interface Story {
  title: string;
  description: string;
}

interface CelebNews {
  celeb: Celeb;
  stories: Story[];
}

interface ScoringResult {
  tier: string;
  net_delta: number;
  story_volume: number;
  reason: string;
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });

  const currentsApiKey = Deno.env.get('CURRENTS_API_KEY');
  if (!currentsApiKey) {
    return jsonResponse({
      error: 'CURRENTS_API_KEY not set — add it in Supabase Dashboard → Project Settings → Edge Functions → Secrets',
    }, 500);
  }

  const anthropicApiKey = Deno.env.get('ANTHROPIC_API_KEY');
  if (!anthropicApiKey) {
    return jsonResponse({ error: 'ANTHROPIC_API_KEY not set' }, 500);
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  if (!supabaseUrl || !serviceRoleKey) {
    return jsonResponse({ error: 'Server misconfigured' }, 500);
  }

  const db = createClient(supabaseUrl, serviceRoleKey);
  const now = new Date();
  let weekId: string;

  try {
    const body = req.method === 'POST' ? await req.json().catch(() => ({})) : {};
    weekId = (body as { week_id?: string }).week_id ?? getIsoWeekId(now);
  } catch {
    weekId = getIsoWeekId(now);
  }

  const scoringWindow = getScoringWindow(now);

  // ── Fetch all active celebs ──────────────────────────────────────────────────
  const { data: celebs, error: celebsError } = await db
    .from('celebs')
    .select('id, name, aliases, category')
    .eq('active', true);

  if (celebsError || !celebs) {
    return jsonResponse({ error: 'Failed to fetch celebs', detail: celebsError?.message }, 500);
  }

  // ── Fetch news from Currents API for each celeb ─────────────────────────────
  const start24h = new Date(now.getTime() - 86400000).toISOString();
  const celebNews: CelebNews[] = [];
  let skipped = 0;

  for (const celeb of celebs as Celeb[]) {
    const keywords = [celeb.name, ...celeb.aliases].join(' OR ');
    const params = new URLSearchParams({
      keywords,
      language: 'en',
      start_date: start24h,
      limit: '10',
    });

    try {
      const res = await fetch(
        `https://api.currentsapi.services/v1/search?${params}`,
        { headers: { Authorization: currentsApiKey } },
      );

      if (res.status === 429) {
        console.warn(`[hot-topic] 429 rate limit for ${celeb.name} — skipping`);
        skipped++;
        celebNews.push({ celeb, stories: [] });
        continue;
      }

      if (!res.ok) {
        console.warn(`[hot-topic] Currents API ${res.status} for ${celeb.name}`);
        celebNews.push({ celeb, stories: [] });
        continue;
      }

      const data = await res.json();
      const news: Story[] = ((data.news ?? []) as Array<{ title?: string; description?: string }>)
        .slice(0, 10)
        .map((n) => ({
          title: n.title ?? '',
          description: (n.description ?? '').slice(0, 200),
        }));

      celebNews.push({ celeb, stories: news });
    } catch (e) {
      console.warn(`[hot-topic] Fetch error for ${celeb.name}:`, e);
      celebNews.push({ celeb, stories: [] });
    }
  }

  // ── Build Anthropic scoring prompt ───────────────────────────────────────────
  const celebDataBlock = celebNews
    .map(({ celeb, stories }) => {
      if (stories.length === 0) {
        return `${celeb.name} (0 stories):\n(no stories this period)`;
      }
      const lines = stories.map((s) => `- "${s.title}" — ${s.description}`).join('\n');
      return `${celeb.name} (${stories.length} stories):\n${lines}`;
    })
    .join('\n\n');

  const prompt = `You are the official scorer for the "Who's Hot Right Now?" leaderboard.

Below are ${celebNews.length} celebrities and their recent news stories from the last 24 hours.

${celebDataBlock}

Rules:
- Analyze ONLY the stories provided.
- Assign ONE net tier per celebrity using this exact table:
  Good 4 (+10): Viral win, major award, record-breaking event, massive praise
  Good 3 (+7): Strong positive achievement, wholesome viral moment
  Good 2 (+4): Positive mention, favorable coverage
  Good 1 (+1): Mildly positive or neutral but flattering coverage
  Neutral (0): Purely factual or zero stories
  Bad 1 (-1): Mild criticism
  Bad 2 (-4): Controversy, backlash
  Bad 3 (-7): Serious negative (scandal, arrest rumors)
  Bad 4 (-10): Major career-damaging event, widespread outrage
- If a celeb has zero stories, assign Neutral (0).
- Output ONLY valid JSON, no extra text, no markdown fences:

{
  "Taylor Swift": { "tier": "Good 3", "net_delta": 7, "story_volume": 4, "reason": "one-sentence explanation" },
  ...
}`;

  // ── Call Anthropic API ───────────────────────────────────────────────────────
  let scoringMap: Record<string, ScoringResult> = {};

  try {
    const aiRes = await fetch('https://api.anthropic.com/v1/messages', {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': anthropicApiKey,
        'anthropic-version': '2023-06-01',
      },
      body: JSON.stringify({
        model: 'claude-sonnet-4-6',
        max_tokens: 2000,
        messages: [{ role: 'user', content: prompt }],
      }),
    });

    if (!aiRes.ok) {
      const errBody = await aiRes.text();
      console.error('[hot-topic] Anthropic API error:', errBody);
      return jsonResponse({ error: 'Anthropic API error', detail: errBody }, 500);
    }

    const aiData = await aiRes.json();
    const rawContent: string = aiData?.content?.[0]?.text ?? '{}';
    // Strip markdown fences if present
    const cleaned = rawContent.replace(/^```json\s*/m, '').replace(/```\s*$/m, '').trim();
    scoringMap = JSON.parse(cleaned);
  } catch (e) {
    console.error('[hot-topic] Failed to parse Anthropic response:', e);
    return jsonResponse({ error: 'Failed to parse AI scoring response' }, 500);
  }

  // ── Apply scores + resolve simple bets ──────────────────────────────────────
  let celebsScored = 0;
  const tierMultipliers: Record<string, number> = {
    'Good 4': 1.5, 'Bad 4': 1.5,
    'Good 3': 1.2, 'Bad 3': 1.2,
  };

  for (const { celeb } of celebNews) {
    const raw = scoringMap[celeb.name];
    if (!raw) continue;

    let delta = raw.net_delta ?? 0;
    const storyVolume = raw.story_volume ?? 0;
    const tier = raw.tier ?? 'Neutral';

    // Volume multiplier: > 5 stories + strong tier → multiply delta
    if (storyVolume > 5 && tierMultipliers[tier]) {
      delta = Math.round(delta * tierMultipliers[tier]);
    }

    // Upsert score via DB function: inserts at 1000+delta on first run, increments on subsequent runs
    const { error: scoreError } = await db.rpc('hot_topic_score_celeb', {
      p_week_id: weekId,
      p_celeb_id: celeb.id,
      p_delta: delta,
      p_tier: tier,
      p_story_volume: storyVolume,
      p_reason: raw.reason ?? null,
    });

    if (scoreError) {
      console.error(`[hot-topic] Score upsert error for ${celeb.name}:`, scoreError.message);
      continue;
    }

    // Insert score history row
    await db.from('celeb_score_history').insert({
      week_id: weekId,
      celeb_id: celeb.id,
      tier,
      delta,
      story_volume: storyVolume,
      reason_text: raw.reason ?? null,
      scoring_window: scoringWindow,
      scored_at: now.toISOString(),
    });

    celebsScored++;

    // ── Resolve simple bets for this celeb + this window ──────────────────────
    const { data: bets } = await db
      .from('weekly_bets')
      .select('id, user_id, tokens_wagered, simple_direction')
      .eq('bet_category', 'simple')
      .eq('celeb_id', celeb.id)
      .eq('scoring_window', scoringWindow)
      .eq('status', 'pending');

    if (!bets || bets.length === 0) continue;

    // delta > 0 → up wins; delta < 0 → down wins; delta = 0 → all lose
    const winDirection = delta > 0 ? 'up' : delta < 0 ? 'down' : null;
    const totalPool = (bets as Array<{ tokens_wagered: number }>).reduce(
      (sum, b) => sum + b.tokens_wagered,
      0,
    );
    const winners = (bets as Array<{ id: string; user_id: string; tokens_wagered: number; simple_direction: string }>)
      .filter((b) => b.simple_direction === winDirection);
    const winnerCount = winners.length;
    const platformFee = Math.floor(totalPool * 0.1);
    const prizePool = totalPool - platformFee;

    for (const bet of bets as Array<{ id: string; user_id: string; tokens_wagered: number; simple_direction: string }>) {
      const isWinner = winDirection !== null && bet.simple_direction === winDirection;
      const payout = isWinner && winnerCount > 0 ? Math.floor(prizePool / winnerCount) : 0;

      if (isWinner && payout > 0) {
        await db.rpc('increment_token_balance', { p_user_id: bet.user_id, p_amount: payout });
        await db.from('token_transactions').insert({
          user_id: bet.user_id,
          type: 'bet_won',
          amount: payout,
          reference_id: bet.id,
          description: `Won Hot Topic simple bet on ${celeb.name}`,
        });
      } else {
        await db.from('token_transactions').insert({
          user_id: bet.user_id,
          type: 'bet_lost',
          amount: 0,
          reference_id: bet.id,
          description: `Lost Hot Topic simple bet on ${celeb.name}`,
        });
      }

      await db
        .from('weekly_bets')
        .update({ status: isWinner ? 'won' : 'lost', payout: isWinner ? payout : 0 })
        .eq('id', bet.id);
    }
  }

  // ── Recompute ranks for all celebs in this week ──────────────────────────────
  const { data: allScores } = await db
    .from('celeb_weekly_scores')
    .select('id, points')
    .eq('week_id', weekId)
    .order('points', { ascending: false });

  if (allScores) {
    for (let i = 0; i < (allScores as Array<{ id: string; points: number }>).length; i++) {
      await db
        .from('celeb_weekly_scores')
        .update({ rank: i + 1 })
        .eq('id', (allScores as Array<{ id: string }>)[i].id);
    }
  }

  return jsonResponse({
    week_id: weekId,
    scoring_window: scoringWindow,
    celebs_scored: celebsScored,
    celebs_skipped: skipped,
    simple_bets_resolved: true,
  });
});
