// supabase/functions/evaluate-challenges/index.ts
//
// Evaluates all active challenges for a user after a qualifying event, awards
// tokens and badges where conditions are met.
//
// Authentication:
//   • User JWT   → Authorization: Bearer {userJWT}     (Flutter client, check_in/bet_placed)
//   • Service    → Authorization: Bearer {serviceKey}  + body.user_id (resolve-markets, apply-promotion)
//
// POST body: { user_id?: string, event: EventType, metadata?: Record<string, unknown> }
// Returns:   { challenges_completed: string[], badges_awarded: string[], tokens_awarded: number }
//
// Idempotency: completed_at IS NULL guard + UNIQUE(user_id, badge_id) prevent
// double-awarding on duplicate calls.

import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

type EventType =
  | 'bet_placed'
  | 'bet_won'
  | 'bet_lost'
  | 'bet_placed_unique_mm'
  | 'bet_won_minority'
  | 'market_resolution_top_stake'
  | 'tokens_spent'
  | 'tokens_earned'
  | 'referral_signup'
  | 'promotion_used'
  | 'bet_resolved_win'
  | 'spotlight_entered'
  | 'power_up_received'
  | 'check_in';

interface ChallengeDefinition {
  id: string;
  slug: string;
  badge_id: string | null;
  track: 'daily' | 'weekly' | 'monthly' | 'once';
  condition: Record<string, unknown>;
  token_reward: number;
  pool: 'all' | 'mm';
}

// ─────────────────────────────────────────────────────────────────────────────
// Period key helpers
// ─────────────────────────────────────────────────────────────────────────────

function getPeriodKey(track: string): string {
  const now = new Date();
  switch (track) {
    case 'daily':
      return now.toISOString().slice(0, 10); // yyyy-MM-dd
    case 'weekly': {
      // ISO 8601 week number
      const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
      const day = d.getUTCDay() || 7;
      d.setUTCDate(d.getUTCDate() + 4 - day);
      const yearStart = new Date(Date.UTC(d.getUTCFullYear(), 0, 1));
      const weekNo = Math.ceil(((d.getTime() - yearStart.getTime()) / 86400000 + 1) / 7);
      return `${d.getUTCFullYear()}-W${String(weekNo).padStart(2, '0')}`;
    }
    case 'monthly':
      return now.toISOString().slice(0, 7); // yyyy-MM
    case 'once':
    default:
      return 'once';
  }
}

function getWeekStart(): Date {
  const now = new Date();
  const d = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const day = d.getUTCDay() || 7;
  d.setUTCDate(d.getUTCDate() - day + 1); // Monday
  return d;
}

// ─────────────────────────────────────────────────────────────────────────────
// Condition → event matcher
// Returns true if this challenge listens to the incoming event.
// ─────────────────────────────────────────────────────────────────────────────

function challengeListensToEvent(condition: Record<string, unknown>, event: EventType): boolean {
  const type = condition.type as string;
  switch (type) {
    case 'count_threshold':
      return condition.event === event;
    case 'snapshot': {
      const field = condition.field as string;
      if (field === 'last_seen') return event === 'check_in';
      if (field === 'created_at') return event === 'check_in'; // evaluated on daily check-in
      if (field === 'spotlight_pinned_until') return event === 'spotlight_entered';
      return false;
    }
    case 'streak':
      // Only fire on the increment event; reset is handled separately via updateStreaks()
      return condition.event === event;
    case 'composite': {
      if (condition.all_events) return event === 'promotion_used';
      if (condition.win_rate_min !== undefined) return event === 'bet_won';
      // contrarian: composite with explicit event field
      if (condition.event) return condition.event === event;
      return false;
    }
    default:
      return false;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Award helper: insert badge, ignore duplicate
// ─────────────────────────────────────────────────────────────────────────────

async function awardBadge(
  db: SupabaseClient,
  userId: string,
  badgeId: string,
  challengeId: string | null,
): Promise<string | null> {
  const { data: existing } = await db
    .from('user_badges')
    .select('id')
    .eq('user_id', userId)
    .eq('badge_id', badgeId)
    .maybeSingle();
  if (existing) return null; // already earned

  const { error } = await db.from('user_badges').insert({
    user_id: userId,
    badge_id: badgeId,
    challenge_id: challengeId,
  });
  if (error) {
    if (error.code === '23505') return null; // unique violation — race condition, safe to ignore
    console.error('awardBadge error:', error);
    return null;
  }

  const { data: badgeDef } = await db
    .from('badge_definitions')
    .select('slug')
    .eq('id', badgeId)
    .single();
  return badgeDef?.slug ?? null;
}

// ─────────────────────────────────────────────────────────────────────────────
// Award tokens for challenge completion
// ─────────────────────────────────────────────────────────────────────────────

async function awardTokens(
  db: SupabaseClient,
  userId: string,
  amount: number,
  challengeId: string,
): Promise<void> {
  const { error: creditError } = await db.rpc('increment_token_balance', {
    p_user_id: userId,
    p_amount: amount,
  });
  if (creditError) {
    console.error(`Token award failed for challenge ${challengeId}:`, creditError);
    return;
  }
  await db.from('token_transactions').insert({
    user_id: userId,
    type: 'challenge_reward',
    amount,
    reference_id: challengeId,
    description: `Challenge reward`,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Streak management: increment or reset a streak, return new count
// ─────────────────────────────────────────────────────────────────────────────

async function updateStreak(
  db: SupabaseClient,
  userId: string,
  streakType: string,
  increment: boolean,
): Promise<number> {
  const { data: existing } = await db
    .from('user_streaks')
    .select('id, current_count')
    .eq('user_id', userId)
    .eq('streak_type', streakType)
    .maybeSingle();

  const newCount = increment ? (existing?.current_count ?? 0) + 1 : 0;

  if (existing) {
    await db.from('user_streaks').update({
      current_count: newCount,
      last_event_at: new Date().toISOString(),
    }).eq('id', existing.id);
  } else if (increment) {
    await db.from('user_streaks').insert({
      user_id: userId,
      streak_type: streakType,
      current_count: newCount,
      last_event_at: new Date().toISOString(),
    });
  }
  return newCount;
}

// ─────────────────────────────────────────────────────────────────────────────
// Handle streak events: update user_streaks and check streak-based challenges
// Called for bet_won and bet_lost events.
// ─────────────────────────────────────────────────────────────────────────────

async function handleStreakEvents(
  db: SupabaseClient,
  userId: string,
  event: EventType,
  streakChallenges: ChallengeDefinition[],
): Promise<{ badgesAwarded: string[]; completedSlugs: string[] }> {
  const badgesAwarded: string[] = [];
  const completedSlugs: string[] = [];

  if (event !== 'bet_won' && event !== 'bet_lost') return { badgesAwarded, completedSlugs };

  // Update streaks bidirectionally
  const wonStreakCount = await updateStreak(db, userId, 'bet_won', event === 'bet_won');
  const lostStreakCount = await updateStreak(db, userId, 'bet_lost', event === 'bet_lost');

  // Evaluate streak-based once challenges
  for (const challenge of streakChallenges) {
    const cond = challenge.condition;
    if (cond.type !== 'streak') continue;

    const streakEvent = cond.event as string;
    if (streakEvent !== event) continue; // Only check challenges whose streak_type matches

    const requiredCount = cond.count as number;
    const currentStreakCount = event === 'bet_won' ? wonStreakCount : lostStreakCount;

    if (currentStreakCount < requiredCount) continue;

    // Check if already completed (once challenges use 'once' period key)
    const periodKey = getPeriodKey(challenge.track);
    const { data: progress } = await db
      .from('user_challenge_progress')
      .select('id, completed_at, tokens_awarded')
      .eq('user_id', userId)
      .eq('challenge_id', challenge.id)
      .eq('period_key', periodKey)
      .maybeSingle();

    if (progress?.completed_at) continue; // already done

    // Mark complete
    const now = new Date().toISOString();
    if (progress) {
      await db.from('user_challenge_progress').update({
        current_count: currentStreakCount,
        completed_at: now,
        tokens_awarded: challenge.token_reward > 0,
      }).eq('id', progress.id);
    } else {
      await db.from('user_challenge_progress').insert({
        user_id: userId,
        challenge_id: challenge.id,
        period_key: periodKey,
        current_count: currentStreakCount,
        completed_at: now,
        tokens_awarded: challenge.token_reward > 0,
      });
    }

    completedSlugs.push(challenge.slug);

    if (challenge.token_reward > 0) {
      await awardTokens(db, userId, challenge.token_reward, challenge.id);
    }

    if (challenge.badge_id) {
      const slug = await awardBadge(db, userId, challenge.badge_id, challenge.id);
      if (slug) badgesAwarded.push(slug);
    }
  }

  return { badgesAwarded, completedSlugs };
}

// ─────────────────────────────────────────────────────────────────────────────
// Process a single count_threshold or snapshot challenge
// ─────────────────────────────────────────────────────────────────────────────

async function processCountThresholdChallenge(
  db: SupabaseClient,
  userId: string,
  challenge: ChallengeDefinition,
  event: EventType,
  metadata: Record<string, unknown>,
): Promise<{ completed: boolean; badgeSlug: string | null }> {
  const cond = challenge.condition;
  const periodKey = getPeriodKey(challenge.track);
  const requiredCount = (cond.count as number) ?? 1;

  // Increment amount: tokens_earned and tokens_spent use the metadata.amount
  const incrementBy = (event === 'tokens_earned' || event === 'tokens_spent')
    ? Math.max(1, Math.floor((metadata.amount as number) ?? 1))
    : 1;

  // Fetch existing progress row
  const { data: existing } = await db
    .from('user_challenge_progress')
    .select('id, current_count, completed_at, tokens_awarded')
    .eq('user_id', userId)
    .eq('challenge_id', challenge.id)
    .eq('period_key', periodKey)
    .maybeSingle();

  if (existing?.completed_at) return { completed: false, badgeSlug: null }; // idempotent

  const newCount = (existing?.current_count ?? 0) + incrementBy;
  const isComplete = newCount >= requiredCount;
  const now = new Date().toISOString();

  if (existing) {
    await db.from('user_challenge_progress').update({
      current_count: newCount,
      ...(isComplete ? { completed_at: now, tokens_awarded: challenge.token_reward > 0 } : {}),
    }).eq('id', existing.id);
  } else {
    await db.from('user_challenge_progress').insert({
      user_id: userId,
      challenge_id: challenge.id,
      period_key: periodKey,
      current_count: newCount,
      ...(isComplete ? { completed_at: now, tokens_awarded: challenge.token_reward > 0 } : {}),
    });
  }

  if (!isComplete) return { completed: false, badgeSlug: null };

  if (challenge.token_reward > 0) {
    await awardTokens(db, userId, challenge.token_reward, challenge.id);
  }

  let badgeSlug: string | null = null;
  if (challenge.badge_id) {
    badgeSlug = await awardBadge(db, userId, challenge.badge_id, challenge.id);
  }

  return { completed: true, badgeSlug };
}

// ─────────────────────────────────────────────────────────────────────────────
// Process a snapshot challenge (check_in, created_at, spotlight_pinned_until)
// ─────────────────────────────────────────────────────────────────────────────

async function processSnapshotChallenge(
  db: SupabaseClient,
  userId: string,
  challenge: ChallengeDefinition,
  event: EventType,
): Promise<{ completed: boolean; badgeSlug: string | null }> {
  const cond = challenge.condition;
  const field = cond.field as string;
  const periodKey = getPeriodKey(challenge.track);

  // Check existing progress
  const { data: existing } = await db
    .from('user_challenge_progress')
    .select('id, completed_at')
    .eq('user_id', userId)
    .eq('challenge_id', challenge.id)
    .eq('period_key', periodKey)
    .maybeSingle();

  if (existing?.completed_at) return { completed: false, badgeSlug: null };

  // Evaluate condition
  let conditionMet = false;

  if (field === 'last_seen' && event === 'check_in') {
    // Daily check-in: just being here completes it
    conditionMet = true;
  } else if (field === 'created_at' && event === 'check_in') {
    // OG / Early Adopter: compare profile created_at against the before date
    const before = cond.before as string;
    const { data: profile } = await db
      .from('profiles')
      .select('created_at')
      .eq('id', userId)
      .single();
    conditionMet = !!profile && profile.created_at < before;
  } else if (field === 'spotlight_pinned_until' && event === 'spotlight_entered') {
    // Spotlight badge: user has an active spotlight_entry boost
    const now = new Date().toISOString();
    const { data: boost } = await db
      .from('active_boosts')
      .select('id')
      .eq('target_user_id', userId)
      .eq('boost_type', 'spotlight_entry')
      .eq('is_cancelled', false)
      .gt('expires_at', now)
      .limit(1)
      .maybeSingle();
    conditionMet = boost !== null;
  }

  if (!conditionMet) return { completed: false, badgeSlug: null };

  const now = new Date().toISOString();
  if (existing) {
    await db.from('user_challenge_progress').update({
      current_count: 1,
      completed_at: now,
      tokens_awarded: challenge.token_reward > 0,
    }).eq('id', existing.id);
  } else {
    await db.from('user_challenge_progress').insert({
      user_id: userId,
      challenge_id: challenge.id,
      period_key: periodKey,
      current_count: 1,
      completed_at: now,
      tokens_awarded: challenge.token_reward > 0,
    });
  }

  if (challenge.token_reward > 0) {
    await awardTokens(db, userId, challenge.token_reward, challenge.id);
  }

  let badgeSlug: string | null = null;
  if (challenge.badge_id) {
    badgeSlug = await awardBadge(db, userId, challenge.badge_id, challenge.id);
  }

  return { completed: true, badgeSlug };
}

// ─────────────────────────────────────────────────────────────────────────────
// Process a composite challenge
// ─────────────────────────────────────────────────────────────────────────────

async function processCompositeChallenge(
  db: SupabaseClient,
  userId: string,
  challenge: ChallengeDefinition,
  event: EventType,
  metadata: Record<string, unknown>,
): Promise<{ completed: boolean; badgeSlug: string | null }> {
  const cond = challenge.condition;
  const periodKey = getPeriodKey(challenge.track);

  const { data: existing } = await db
    .from('user_challenge_progress')
    .select('id, current_count, completed_at')
    .eq('user_id', userId)
    .eq('challenge_id', challenge.id)
    .eq('period_key', periodKey)
    .maybeSingle();

  if (existing?.completed_at) return { completed: false, badgeSlug: null };

  let conditionMet = false;
  let newCount = existing?.current_count ?? 0;

  if (cond.all_events && event === 'promotion_used') {
    // power_user: check if user has used all required boost types ever
    const requiredTypes = cond.all_events as string[];
    const { data: usedBoosts } = await db
      .from('active_boosts')
      .select('boost_type')
      .eq('activated_by_user_id', userId)
      .in('boost_type', requiredTypes);

    const usedTypes = new Set((usedBoosts ?? []).map((b: { boost_type: string }) => b.boost_type));
    conditionMet = requiredTypes.every((t) => usedTypes.has(t));
    newCount = usedTypes.size;
  } else if (cond.win_rate_min !== undefined && event === 'bet_won') {
    // market_oracle: check win rate across all resolved bets
    const { data: betsData } = await db
      .from('bets')
      .select('status')
      .eq('user_id', userId)
      .in('status', ['won', 'lost']);

    const total = (betsData ?? []).length;
    const won = (betsData ?? []).filter((b: { status: string }) => b.status === 'won').length;
    const winRate = total > 0 ? won / total : 0;
    conditionMet = total >= (cond.min_bets as number) && winRate >= (cond.win_rate_min as number);
    newCount = total;
  } else if (cond.event === 'bet_won_minority' && event === 'bet_won_minority') {
    // contrarian: count minority wins
    const requiredCount = cond.count as number;
    newCount = (existing?.current_count ?? 0) + 1;
    conditionMet = newCount >= requiredCount;
  }

  if (!conditionMet && cond.event !== 'bet_won_minority') {
    // For non-counting composites, still save progress
    if (newCount !== (existing?.current_count ?? 0)) {
      if (existing) {
        await db.from('user_challenge_progress').update({ current_count: newCount }).eq('id', existing.id);
      } else {
        await db.from('user_challenge_progress').insert({
          user_id: userId, challenge_id: challenge.id, period_key: periodKey, current_count: newCount,
        });
      }
    }
    return { completed: false, badgeSlug: null };
  }

  if (!conditionMet) {
    // contrarian: increment but not complete yet
    if (existing) {
      await db.from('user_challenge_progress').update({ current_count: newCount }).eq('id', existing.id);
    } else {
      await db.from('user_challenge_progress').insert({
        user_id: userId, challenge_id: challenge.id, period_key: periodKey, current_count: newCount,
      });
    }
    return { completed: false, badgeSlug: null };
  }

  const now = new Date().toISOString();
  if (existing) {
    await db.from('user_challenge_progress').update({
      current_count: newCount,
      completed_at: now,
      tokens_awarded: challenge.token_reward > 0,
    }).eq('id', existing.id);
  } else {
    await db.from('user_challenge_progress').insert({
      user_id: userId,
      challenge_id: challenge.id,
      period_key: periodKey,
      current_count: newCount,
      completed_at: now,
      tokens_awarded: challenge.token_reward > 0,
    });
  }

  if (challenge.token_reward > 0) {
    await awardTokens(db, userId, challenge.token_reward, challenge.id);
  }

  let badgeSlug: string | null = null;
  if (challenge.badge_id) {
    badgeSlug = await awardBadge(db, userId, challenge.badge_id, challenge.id);
  }

  return { completed: true, badgeSlug };
}

// ─────────────────────────────────────────────────────────────────────────────
// Main handler
// ─────────────────────────────────────────────────────────────────────────────

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return errResp('Method not allowed', 405);

  const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY')!;

  const authHeader = req.headers.get('Authorization') ?? '';

  let body: { user_id?: string; event?: string; metadata?: Record<string, unknown> };
  try { body = await req.json(); } catch { return errResp('Invalid JSON', 400); }

  let userId: string;

  if (authHeader === `Bearer ${serviceRoleKey}`) {
    // Internal service call from other edge functions
    if (!body.user_id) return errResp('user_id required for service calls', 400);
    userId = body.user_id;
  } else {
    // User JWT call (Flutter client: check_in, bet_placed, referral_signup)
    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } },
    });
    const { data: { user }, error: authErr } = await userClient.auth.getUser();
    if (authErr || !user) return errResp('Unauthorized', 401);
    userId = user.id;
  }

  const event = body.event as EventType;
  if (!event) return errResp('event is required', 400);
  const metadata = body.metadata ?? {};

  const db = createClient(supabaseUrl, serviceRoleKey);

  try {
    // ── Check MM eligibility ──────────────────────────────────────────────────
    const { data: metricsRow } = await db
      .from('platform_metrics')
      .select('id')
      .eq('user_id', userId)
      .limit(1)
      .maybeSingle();
    const isMM = metricsRow !== null;

    // ── Special case: referral_signup ────────────────────────────────────────
    // When a newly signed-up user fires this event, we award the challenge to
    // their REFERRER, not to themselves.
    let targetUserId = userId;
    if (event === 'referral_signup') {
      const { data: profile } = await db
        .from('profiles')
        .select('referred_by')
        .eq('id', userId)
        .single();

      if (!profile?.referred_by) {
        return okResp({ challenges_completed: [], badges_awarded: [], tokens_awarded: 0 });
      }
      // Re-evaluate for the referrer, not the new user
      targetUserId = profile.referred_by;
      const { data: referrerMetrics } = await db
        .from('platform_metrics')
        .select('id')
        .eq('user_id', targetUserId)
        .limit(1)
        .maybeSingle();
      // isMM for referrer (used for pool filtering)
      const referrerIsMM = referrerMetrics !== null;

      // Phase 7 deferred: apply passive referral bonus from badge effects
      // Awards an extra lump-sum of tokens to the referrer if they have the
      // referral_bonus badge passive (only kicks in after referral_bonus_after_n total referrals).
      try {
        const { data: passiveRow } = await db
          .from('user_passive_effects')
          .select('referral_bonus_tokens, referral_bonus_after_n')
          .eq('user_id', targetUserId)
          .maybeSingle();
        const bonusTokens = (passiveRow?.referral_bonus_tokens as number | null) ?? 0;
        const bonusAfterN = (passiveRow?.referral_bonus_after_n as number | null) ?? 0;

        if (bonusTokens > 0) {
          const { count } = await db
            .from('profiles')
            .select('id', { count: 'exact', head: true })
            .eq('referred_by', targetUserId);
          if ((count ?? 0) >= bonusAfterN) {
            await db.rpc('increment_token_balance', {
              p_user_id: targetUserId, p_amount: bonusTokens,
            });
            await db.from('token_transactions').insert({
              user_id: targetUserId,
              type: 'referral_bonus',
              amount: bonusTokens,
              description: 'Badge referral bonus',
            });
          }
        }
      } catch (e) {
        console.error('Passive referral bonus error:', e);
      }

      return await evaluateChallengesForUser(db, targetUserId, referrerIsMM, event, metadata);
    }

    return await evaluateChallengesForUser(db, targetUserId, isMM, event, metadata);
  } catch (err) {
    console.error('evaluate-challenges error:', err);
    return errResp('Internal server error', 500);
  }
});

// ─────────────────────────────────────────────────────────────────────────────
// Core evaluation loop
// ─────────────────────────────────────────────────────────────────────────────

async function evaluateChallengesForUser(
  db: SupabaseClient,
  userId: string,
  isMM: boolean,
  event: EventType,
  metadata: Record<string, unknown>,
): Promise<Response> {
  const now = new Date().toISOString();

  // Load all active challenges the user is eligible for (pool filtering)
  const { data: challenges, error: challengeErr } = await db
    .from('challenge_definitions')
    .select('id, slug, badge_id, track, condition, token_reward, pool')
    .eq('is_active', true)
    .or(`starts_at.is.null,starts_at.lte.${now}`)
    .or(`ends_at.is.null,ends_at.gt.${now}`)
    .in('pool', isMM ? ['all', 'mm'] : ['all']);

  if (challengeErr) {
    console.error('Failed to load challenges:', challengeErr);
    return errResp('Failed to load challenges', 500);
  }

  const allChallenges = (challenges ?? []) as ChallengeDefinition[];
  const completedSlugs: string[] = [];
  const awardedBadgeSlugs: string[] = [];
  let totalTokens = 0;

  // Partition challenges by condition type and relevance to this event
  const streakChallenges = allChallenges.filter(
    (c) => c.condition.type === 'streak',
  );
  const relevantChallenges = allChallenges.filter(
    (c) => challengeListensToEvent(c.condition, event),
  );

  // ── Handle streak updates + streak-based challenge completion ─────────────
  if (event === 'bet_won' || event === 'bet_lost') {
    const streakResult = await handleStreakEvents(db, userId, event, streakChallenges);
    completedSlugs.push(...streakResult.completedSlugs);
    awardedBadgeSlugs.push(...streakResult.badgesAwarded);
  }

  // ── Process each matching challenge ───────────────────────────────────────
  for (const challenge of relevantChallenges) {
    const condType = challenge.condition.type as string;

    try {
      let result: { completed: boolean; badgeSlug: string | null } = {
        completed: false,
        badgeSlug: null,
      };

      if (condType === 'count_threshold') {
        result = await processCountThresholdChallenge(db, userId, challenge, event, metadata);
      } else if (condType === 'snapshot') {
        result = await processSnapshotChallenge(db, userId, challenge, event);
      } else if (condType === 'composite') {
        result = await processCompositeChallenge(db, userId, challenge, event, metadata);
      }
      // 'streak' challenges are handled via handleStreakEvents above

      if (result.completed) {
        completedSlugs.push(challenge.slug);
        if (challenge.token_reward > 0) totalTokens += challenge.token_reward;
        if (result.badgeSlug) awardedBadgeSlugs.push(result.badgeSlug);
      }
    } catch (err) {
      console.error(`Challenge ${challenge.slug} processing error:`, err);
      // Continue with next challenge — one failure doesn't block others
    }
  }

  return okResp({
    challenges_completed: completedSlugs,
    badges_awarded: awardedBadgeSlugs,
    tokens_awarded: totalTokens,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Response helpers
// ─────────────────────────────────────────────────────────────────────────────

function okResp(data: Record<string, unknown>): Response {
  return new Response(JSON.stringify({ success: true, ...data }), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}

function errResp(message: string, status: number): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}
