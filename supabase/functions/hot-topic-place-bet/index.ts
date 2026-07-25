// supabase/functions/hot-topic-place-bet/index.ts
// Auth required. Places a simple (per-window up/down) or weekly bet on a celeb.
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

// Friday 8 PM ET = Saturday 00:00 UTC. Weekly bets close at that point.
function isWeeklyBettingClosed(date: Date): boolean {
  const day = date.getUTCDay(); // 0=Sun, 6=Sat
  return day === 6 || day === 0;
}

serve(async (req: Request) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });

  // ── Auth: get user from JWT ──────────────────────────────────────────────────
  const authHeader = req.headers.get('Authorization');
  if (!authHeader) return jsonResponse({ error: 'Authentication required' }, 401);

  const supabaseUrl = Deno.env.get('SUPABASE_URL') ?? '';
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';

  if (!supabaseUrl || !serviceRoleKey) {
    return jsonResponse({ error: 'Server misconfigured' }, 500);
  }

  const userClient = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authHeader } },
  });
  const { data: { user }, error: authError } = await userClient.auth.getUser();
  if (authError || !user) return jsonResponse({ error: 'Authentication required' }, 401);

  const db = createClient(supabaseUrl, serviceRoleKey);
  const now = new Date();

  // ── Parse body ───────────────────────────────────────────────────────────────
  let body: {
    bet_category?: string;
    weekly_bet_type?: string;
    simple_direction?: string;
    celeb_id?: string;
    tokens_wagered?: number;
  };
  try {
    body = await req.json();
  } catch {
    return jsonResponse({ error: 'Invalid JSON body' }, 400);
  }

  const { bet_category, weekly_bet_type, simple_direction, celeb_id, tokens_wagered } = body;

  if (!bet_category || !['simple', 'weekly'].includes(bet_category)) {
    return jsonResponse({ error: 'bet_category must be "simple" or "weekly"' }, 400);
  }
  if (!tokens_wagered || tokens_wagered < 10) {
    return jsonResponse({ error: 'Minimum wager is 10 tokens' }, 400);
  }

  const weekId = getIsoWeekId(now);

  // ── Validate by bet type ─────────────────────────────────────────────────────
  let scoringWindow: string | null = null;

  if (bet_category === 'simple') {
    if (!celeb_id) return jsonResponse({ error: 'celeb_id is required for simple bets' }, 400);
    if (!simple_direction || !['up', 'down'].includes(simple_direction)) {
      return jsonResponse({ error: 'simple_direction must be "up" or "down"' }, 400);
    }

    scoringWindow = getScoringWindow(now);

    // Reject if scoring already ran for this window (window closed)
    const { data: historyRow } = await db
      .from('celeb_score_history')
      .select('id')
      .eq('celeb_id', celeb_id)
      .eq('scoring_window', scoringWindow)
      .limit(1)
      .maybeSingle();

    if (historyRow) {
      return jsonResponse({ error: 'This scoring window has already closed. Wait for the next window.' }, 409);
    }
  } else {
    // weekly bet
    const validTypes = ['person_of_week', 'top_riser', 'big_boo', 'top_5'];
    if (!weekly_bet_type || !validTypes.includes(weekly_bet_type)) {
      return jsonResponse({ error: `weekly_bet_type must be one of: ${validTypes.join(', ')}` }, 400);
    }
    if (['person_of_week', 'top_riser'].includes(weekly_bet_type) && !celeb_id) {
      return jsonResponse({ error: `celeb_id is required for ${weekly_bet_type}` }, 400);
    }
    if (isWeeklyBettingClosed(now)) {
      return jsonResponse({ error: 'Weekly betting is closed after Friday 8 PM ET. Results are being tallied.' }, 409);
    }
  }

  // ── Place the bet atomically (debit + bet row + ledger in ONE transaction) ──
  // Was: read balance -> write (balance - wager) -> insert bet -> log. That lost a
  // debit under concurrency, and its failure path restored a STALE absolute
  // balance, clobbering any concurrent change. hot_topic_place_bet_atomic
  // (mig 180) does the debit as a single guarded UPDATE and rolls the whole thing
  // back together if the bet insert violates its uniqueness constraint.
  const { data: betId, error: placeError } = await db.rpc('hot_topic_place_bet_atomic', {
    p_user: user.id,
    p_week_id: weekId,
    p_bet_category: bet_category,
    p_tokens: tokens_wagered,
    p_simple_direction: bet_category === 'simple' ? simple_direction : null,
    p_celeb_id: celeb_id ?? null,
    p_scoring_window: bet_category === 'simple' ? scoringWindow : null,
    p_weekly_bet_type: bet_category === 'simple' ? null : weekly_bet_type,
  });

  if (placeError) {
    const msg = placeError.message ?? '';
    if (msg.includes('Insufficient tokens')) {
      return jsonResponse({ error: 'Insufficient tokens for that wager.' }, 409);
    }
    // 23505 surfaces through the RPC as a duplicate-key message.
    if (placeError.code === '23505' || msg.includes('duplicate key')) {
      return jsonResponse({
        error: bet_category === 'simple'
          ? "You've already bet on this celeb this window"
          : "You've already placed your weekly bet for this week",
      }, 409);
    }
    console.error('hot_topic_place_bet_atomic failed:', msg);
    return jsonResponse({ error: 'Failed to place bet', detail: msg }, 500);
  }

  const insertedBet = { id: betId as string };

  // Read the balance back for the response. The debit already happened inside the
  // RPC, so this is display only — never the basis for a write.
  const { data: afterRow } = await db
    .from('token_balances')
    .select('available_tokens')
    .eq('user_id', user.id)
    .maybeSingle();
  const tokensRemaining =
    (afterRow as { available_tokens?: number } | null)?.available_tokens ?? null;

  return jsonResponse({
    bet_id: insertedBet.id,
    bet_category,
    scoring_window: scoringWindow,
    tokens_remaining: tokensRemaining,
  });
});
