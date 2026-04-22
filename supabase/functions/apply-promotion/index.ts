// supabase/functions/apply-promotion/index.ts
// Phase 7 additions:
//   • Fires evaluate-challenges for promotion_used (activator) and power_up_received (target)
//   • Awards Power Tripped badge directly to target when a power-up is used on them
//   • Awards Untouchable badge to target when black_hole is used and target has
//     an active spotlight_entry boost (they survived the black hole while spotlighted)
// Applies a promotion (self-boost) or power-up (on another Market Maker).
// Deducts tokens, inserts into active_boosts, writes promotion_banners for
// universe/galaxy, and triggers an immediate sync-platform-metrics call.
//
// POST body (standard):    { boost_type, target_user_id }
// POST body (SMBH):        { boost_type: 'super_massive_black_hole', category }
// Returns: { success: true, tokens_spent, effective_delta, expires_at }

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': 'https://noraplatforms.com',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// ─────────────────────────────────────────────────────────────────────────────
// Boost catalogue
// ─────────────────────────────────────────────────────────────────────────────

type BoostType =
  | 'quick_boost' | 'major_boost' | 'spotlight_entry'
  | 'instant_plus' | 'instant_minus'
  | 'universe' | 'galaxy' | 'black_hole' | 'super_massive_black_hole';

interface BoostDef {
  baseCost: number;
  baseDelta: number;
  durationHours: number | null;
  isSelfOnly: boolean;
  requiresTargetMM: boolean;
}

const BOOST_CATALOGUE: Record<BoostType, BoostDef> = {
  quick_boost:               { baseCost: 80,  baseDelta: 8,   durationHours: 1,    isSelfOnly: true,  requiresTargetMM: false },
  major_boost:               { baseCost: 250, baseDelta: 20,  durationHours: 1,    isSelfOnly: true,  requiresTargetMM: false },
  spotlight_entry:           { baseCost: 500, baseDelta: 0,   durationHours: 4,    isSelfOnly: true,  requiresTargetMM: false },
  instant_plus:              { baseCost: 400, baseDelta: 12,  durationHours: 1,    isSelfOnly: false, requiresTargetMM: true  },
  instant_minus:             { baseCost: 350, baseDelta: -12, durationHours: 1,    isSelfOnly: false, requiresTargetMM: true  },
  universe:                  { baseCost: 800, baseDelta: 0,   durationHours: 4,    isSelfOnly: false, requiresTargetMM: true  },
  galaxy:                    { baseCost: 300, baseDelta: 0,   durationHours: 4,    isSelfOnly: false, requiresTargetMM: true  },
  black_hole:                { baseCost: 250, baseDelta: 0,   durationHours: null, isSelfOnly: false, requiresTargetMM: true  },
  super_massive_black_hole:  { baseCost: 800, baseDelta: 0,   durationHours: null, isSelfOnly: false, requiresTargetMM: false },
};

const SELF_BOOST_TYPES: BoostType[] = ['quick_boost', 'major_boost', 'spotlight_entry'];

// ─────────────────────────────────────────────────────────────────────────────
// Handler
// ─────────────────────────────────────────────────────────────────────────────

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS_HEADERS });
  if (req.method !== 'POST') return err('Method not allowed', 405);

  // ── Auth ──────────────────────────────────────────────────────────────────
  const authHeader = req.headers.get('Authorization');
  if (!authHeader) return err('Missing authorization header', 401);

  const userClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_ANON_KEY')!,
    { global: { headers: { Authorization: authHeader } } },
  );
  const { data: { user }, error: authErr } = await userClient.auth.getUser();
  if (authErr || !user) return err('Unauthorized', 401);

  const serviceClient = createClient(
    Deno.env.get('SUPABASE_URL')!,
    Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!,
  );

  // ── Parse body ────────────────────────────────────────────────────────────
  let body: { boost_type?: string; target_user_id?: string; category?: string };
  try { body = await req.json(); } catch { return err('Invalid JSON body', 400); }

  const boostType = body.boost_type as BoostType | undefined;
  if (!boostType || !BOOST_CATALOGUE[boostType]) return err(`Invalid boost_type: ${boostType}`, 400);

  const def = BOOST_CATALOGUE[boostType];

    // ── Badge passive discount (applies to all boost types) ─────────────────────
  // Query once here; used in SMBH, Black Hole, and standard paths below.
  const { data: passiveRow } = await serviceClient
    .from('user_passive_effects')
    .select('promotion_discount')
    .eq('user_id', user.id)
    .maybeSingle();
  const badgeDiscount = (passiveRow?.promotion_discount as number | null) ?? 0;
  // Apply badge discount to base cost before any other adjustments.
  const adjustedBaseCost = badgeDiscount > 0
    ? Math.floor(def.baseCost * (1 - badgeDiscount))
    : def.baseCost;

  // ── Super Massive Black Hole ──────────────────────────────────────────────
  if (boostType === 'super_massive_black_hole') {
    const category = body.category?.trim();
    if (!category) return err('category is required for super_massive_black_hole', 400);

    const now = new Date().toISOString();

    // Find all active Galaxy boosts where target's category_1 matches
    const { data: profiles } = await serviceClient
      .from('profiles')
      .select('id')
      .eq('category_1', category);

    const targetIds = (profiles ?? []).map((p: { id: string }) => p.id);
    if (targetIds.length === 0) return err(`No Market Makers found in category: ${category}`, 400);

    const { data: activeGalaxies } = await serviceClient
      .from('active_boosts')
      .select('id, target_user_id')
      .in('target_user_id', targetIds)
      .eq('boost_type', 'galaxy')
      .eq('is_cancelled', false)
      .gt('expires_at', now);

    if (!activeGalaxies || activeGalaxies.length === 0) {
      return err(`No active Galaxy effects found in category: ${category}`, 400);
    }

    // Check and deduct tokens
    const { data: balRow } = await serviceClient
      .from('token_balances').select('available_tokens').eq('user_id', user.id).single();
    if ((balRow?.available_tokens ?? 0) < adjustedBaseCost) {
      return err(`Insufficient tokens. Need ${adjustedBaseCost}, have ${balRow?.available_tokens ?? 0}.`, 402);
    }

    const { error: deductErr } = await serviceClient.rpc('increment_token_balance', {
      p_user_id: user.id, p_amount: -adjustedBaseCost,
    });
    if (deductErr) return err('Token deduction failed', 500);

    // Cancel all matching active_boosts
    const boostIds = activeGalaxies.map((b: { id: string }) => b.id);
    await serviceClient.from('active_boosts').update({ is_cancelled: true }).in('id', boostIds);

    // Cancel matching promotion_banners
    await serviceClient
      .from('promotion_banners')
      .update({ is_cancelled: true })
      .in('boost_id', boostIds);

    // Record SMBH in active_boosts for history
    await serviceClient.from('active_boosts').insert({
      target_user_id: user.id, // self — no single target for SMBH
      activated_by_user_id: user.id,
      boost_type: 'super_massive_black_hole',
      heat_score_delta: 0,
      tokens_spent: adjustedBaseCost,
      expires_at: null,
      is_cancelled: false,
    });

    await serviceClient.from('token_transactions').insert({
      user_id: user.id,
      amount: -adjustedBaseCost,
      type: 'promoted',
      description: `Super Massive Black Hole — cancelled all Galaxy effects in ${category}`,
    });

    // Phase 7: challenge events for SMBH activator
    fireChallenge(user.id, 'promotion_used', { promotion_type: 'super_massive_black_hole' }).catch(console.error);
    fireChallenge(user.id, 'tokens_spent', { amount: adjustedBaseCost, promotion_type: 'super_massive_black_hole' }).catch(console.error);

    return ok({ tokens_spent: adjustedBaseCost, effective_delta: 0, expires_at: null });
  }

  // ── Standard power-ups: require target_user_id ────────────────────────────
  const targetUserId = body.target_user_id;
  if (!targetUserId) return err('target_user_id is required', 400);
  if (def.isSelfOnly && targetUserId !== user.id) {
    return err(`${boostType} can only be applied to your own profile`, 403);
  }

  const { data: targetProfile, error: profileErr } = await serviceClient
    .from('profiles')
    .select('id, username, is_market_maker, category_1')
    .eq('id', targetUserId)
    .single();
  if (profileErr || !targetProfile) return err('Target profile not found', 404);
  if (def.requiresTargetMM && !targetProfile.is_market_maker) {
    return err('Target must be a Market Maker for this boost type', 403);
  }

  // ── Black Hole: cancel ALL universe + galaxy on target ────────────────────
  if (boostType === 'black_hole') {
    const now = new Date().toISOString();
    const { data: activeBoosts } = await serviceClient
      .from('active_boosts')
      .select('id, boost_type')
      .eq('target_user_id', targetUserId)
      .in('boost_type', ['universe', 'galaxy'])
      .eq('is_cancelled', false)
      .gt('expires_at', now);

    if (!activeBoosts || activeBoosts.length === 0) {
      return err('Target has no active Universe or Galaxy to cancel', 400);
    }

    const { data: balRow } = await serviceClient
      .from('token_balances').select('available_tokens').eq('user_id', user.id).single();
    if ((balRow?.available_tokens ?? 0) < adjustedBaseCost) {
      return err(`Insufficient tokens. Need ${adjustedBaseCost}, have ${balRow?.available_tokens ?? 0}.`, 402);
    }

    const { error: deductErr } = await serviceClient.rpc('increment_token_balance', {
      p_user_id: user.id, p_amount: -adjustedBaseCost,
    });
    if (deductErr) return err('Token deduction failed', 500);

    const boostIds = activeBoosts.map((b: { id: string }) => b.id);
    await serviceClient.from('active_boosts').update({ is_cancelled: true }).in('id', boostIds);
    await serviceClient.from('promotion_banners').update({ is_cancelled: true }).in('boost_id', boostIds);

    await serviceClient.from('active_boosts').insert({
      target_user_id: targetUserId,
      activated_by_user_id: user.id,
      boost_type: 'black_hole',
      heat_score_delta: 0,
      tokens_spent: adjustedBaseCost,
      expires_at: null,
      is_cancelled: false,
    });

    await serviceClient.from('token_transactions').insert({
      user_id: user.id,
      amount: -adjustedBaseCost,
      type: 'promoted',
      description: `Black Hole — cancelled Universe/Galaxy on @${targetProfile.username}`,
    });

    // Phase 7: Power Tripped badge for target, Untouchable badge if still in spotlight
    await awardBadgeBySlug(serviceClient, targetUserId, 'power_tripped');
    await checkAndAwardUntouchable(serviceClient, targetUserId);

    // Phase 7: challenge events
    fireChallenge(user.id, 'promotion_used', { promotion_type: 'black_hole' }).catch(console.error);
    fireChallenge(targetUserId, 'power_up_received', { promotion_type: 'black_hole' }).catch(console.error);
    fireChallenge(user.id, 'tokens_spent', { amount: adjustedBaseCost, promotion_type: 'black_hole' }).catch(console.error);

    triggerSync(targetUserId).catch(console.error);
    return ok({ tokens_spent: adjustedBaseCost, effective_delta: 0, expires_at: null });
  }

  // ── Galaxy: require target to have a category_1 ───────────────────────────
  if (boostType === 'galaxy' && !targetProfile.category_1) {
    return err('Target has no primary category set — Galaxy cannot be applied', 400);
  }

  // ── Cooldown check (Universe / Galaxy) ────────────────────────────────────
  if (boostType === 'universe' || boostType === 'galaxy') {
    const now = new Date().toISOString();
    const { data: existing } = await serviceClient
      .from('active_boosts')
      .select('id')
      .eq('activated_by_user_id', user.id)
      .eq('target_user_id', targetUserId)
      .eq('boost_type', boostType)
      .eq('is_cancelled', false)
      .gt('expires_at', now)
      .limit(1)
      .maybeSingle();
    if (existing) return err(`You already have an active ${boostType} on this creator.`, 409);
  }

  // ── Compute effective cost and delta ─────────────────────────────────────
  // Start from badge-discounted base cost; MM open-market discount is applied on top.
  let effectiveCost = adjustedBaseCost;
  let effectiveDelta = def.baseDelta;

  if (SELF_BOOST_TYPES.includes(boostType)) {
    const { data: openMarket } = await serviceClient
      .from('markets').select('id, above_pool, below_pool')
      .eq('creator_id', user.id).eq('status', 'open').limit(1).maybeSingle();
    if (openMarket) {
      effectiveCost = Math.floor(effectiveCost * 0.8); // 20% MM discount on top of badge discount
      const totalPool = (openMarket.above_pool ?? 0) + (openMarket.below_pool ?? 0);
      if (effectiveDelta > 0 && totalPool >= 200) {
        effectiveDelta = Math.round(effectiveDelta * 1.5);
      }
    }
  }

  // ── Check balance ─────────────────────────────────────────────────────────
  const { data: balRow } = await serviceClient
    .from('token_balances').select('available_tokens').eq('user_id', user.id).single();
  if ((balRow?.available_tokens ?? 0) < effectiveCost) {
    return err(`Insufficient tokens. Need ${effectiveCost}, have ${balRow?.available_tokens ?? 0}.`, 402);
  }

  // ── Deduct tokens ─────────────────────────────────────────────────────────
  const { error: deductErr } = await serviceClient.rpc('increment_token_balance', {
    p_user_id: user.id, p_amount: -effectiveCost,
  });
  if (deductErr) return err('Token deduction failed', 500);

  // ── Compute expiry ────────────────────────────────────────────────────────
  let expiresAt: string | null = null;
  if (def.durationHours !== null) {
    expiresAt = new Date(Date.now() + def.durationHours * 60 * 60 * 1000).toISOString();
  }

  // ── Insert active_boost ───────────────────────────────────────────────────
  const { data: boostRow, error: insertErr } = await serviceClient
    .from('active_boosts')
    .insert({
      target_user_id: targetUserId,
      activated_by_user_id: user.id,
      boost_type: boostType,
      heat_score_delta: effectiveDelta,
      tokens_spent: effectiveCost,
      expires_at: expiresAt,
      is_cancelled: false,
    })
    .select('id').single();

  if (insertErr) {
    await serviceClient.rpc('increment_token_balance', { p_user_id: user.id, p_amount: effectiveCost });
    return err('Failed to apply boost. Tokens refunded.', 500);
  }

  // ── Insert promotion_banner for universe / galaxy ─────────────────────────
  if (boostType === 'universe' || boostType === 'galaxy') {
    await serviceClient.from('promotion_banners').insert({
      boost_id: boostRow.id,
      type: boostType,
      target_user_id: targetUserId,
      target_username: targetProfile.username,
      category: boostType === 'galaxy' ? targetProfile.category_1 : null,
      expires_at: expiresAt,
      is_cancelled: false,
    });
  }

  // ── Log transaction ───────────────────────────────────────────────────────
  const descMap: Record<BoostType, string> = {
    quick_boost:              `Quick Boost — +${effectiveDelta} heat for 1h`,
    major_boost:              `Major Boost — +${effectiveDelta} heat for 1h`,
    spotlight_entry:          'Spotlight Entry — guaranteed slot for 4h',
    instant_plus:             `+Popularity — +${effectiveDelta} heat for 1h`,
    instant_minus:            `-Popularity — ${effectiveDelta} heat for 1h`,
    universe:                 `Universe — global banner for 4h on @${targetProfile.username}`,
    galaxy:                   `Galaxy — category banner for 4h on @${targetProfile.username}`,
    black_hole:               `Black Hole — cancelled Universe/Galaxy on @${targetProfile.username}`,
    super_massive_black_hole: 'Super Massive Black Hole — cancelled category Galaxy',
  };

  await serviceClient.from('token_transactions').insert({
    user_id: user.id,
    amount: -effectiveCost,
    type: 'promoted',
    description: descMap[boostType],
    reference_id: boostRow.id,
  });

  // Phase 7: Power Tripped badge for target (only when used on another user)
  if (!def.isSelfOnly && targetUserId !== user.id) {
    awardBadgeBySlug(serviceClient, targetUserId, 'power_tripped').catch(console.error);
    fireChallenge(targetUserId, 'power_up_received', { promotion_type: boostType }).catch(console.error);
  }

  // Phase 7: challenge events for activator
  fireChallenge(user.id, 'promotion_used', { promotion_type: boostType }).catch(console.error);
  fireChallenge(user.id, 'tokens_spent', { amount: effectiveCost, promotion_type: boostType }).catch(console.error);

  triggerSync(targetUserId).catch(console.error);
  return ok({ tokens_spent: effectiveCost, effective_delta: effectiveDelta, expires_at: expiresAt });
});

// ─────────────────────────────────────────────────────────────────────────────
// Helpers
// ─────────────────────────────────────────────────────────────────────────────

async function triggerSync(userId: string): Promise<void> {
  const fnUrl = `${Deno.env.get('SUPABASE_URL')}/functions/v1/sync-platform-metrics`;
  await fetch(fnUrl, {
    method: 'POST',
    headers: {
      Authorization: `Bearer ${Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')}`,
      'Content-Type': 'application/json',
    },
    body: JSON.stringify({ user_id: userId }),
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// Phase 7 helpers
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

async function awardBadgeBySlug(
  serviceClient: ReturnType<typeof createClient>,
  userId: string,
  badgeSlug: string,
): Promise<void> {
  const { data: badge } = await serviceClient
    .from('badge_definitions')
    .select('id')
    .eq('slug', badgeSlug)
    .single();
  if (!badge) return;

  const { error } = await serviceClient.from('user_badges').insert({
    user_id: userId,
    badge_id: badge.id,
    challenge_id: null,
  });
  if (error && error.code !== '23505') {
    console.error(`awardBadgeBySlug(${badgeSlug}) error:`, error);
  }
}

async function checkAndAwardUntouchable(
  serviceClient: ReturnType<typeof createClient>,
  targetUserId: string,
): Promise<void> {
  // Award Untouchable if target has an active spotlight_entry boost (still pinned)
  const now = new Date().toISOString();
  const { data: spotlightBoost } = await serviceClient
    .from('active_boosts')
    .select('id')
    .eq('target_user_id', targetUserId)
    .eq('boost_type', 'spotlight_entry')
    .eq('is_cancelled', false)
    .gt('expires_at', now)
    .limit(1)
    .maybeSingle();

  if (spotlightBoost) {
    await awardBadgeBySlug(serviceClient, targetUserId, 'untouchable');
  }
}

function ok(data: Record<string, unknown>): Response {
  return new Response(JSON.stringify({ success: true, ...data }), {
    status: 200,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}

function err(message: string, status: number): Response {
  return new Response(JSON.stringify({ error: message }), {
    status,
    headers: { ...CORS_HEADERS, 'Content-Type': 'application/json' },
  });
}
