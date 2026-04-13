// supabase/functions/apply-promotion/index.ts
// Applies a promotion (self-boost) or power-up (on another Market Maker).
// Deducts tokens, inserts into active_boosts, and triggers an immediate
// sync-platform-metrics call so heat_score updates without waiting 5 minutes.
//
// POST body: { boost_type: string, target_user_id: string }
// Returns:   { success: true, tokens_spent: number, effective_delta: number, expires_at: string | null }

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const CORS_HEADERS = {
  'Access-Control-Allow-Origin': 'https://nora-platforms.vercel.app',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};

// ─────────────────────────────────────────────────────────────────────────────
// Boost catalogue
// ─────────────────────────────────────────────────────────────────────────────

type BoostType =
  | 'quick_boost'
  | 'major_boost'
  | 'spotlight_entry'
  | 'instant_plus'
  | 'instant_minus'
  | 'universe'
  | 'galaxy'
  | 'black_hole';

interface BoostDef {
  baseCost: number;
  baseDelta: number;       // signed heat_score change; 0 = cosmetic only
  durationHours: number | null; // null = instant (no expiry row)
  isSelfOnly: boolean;    // true = caller must be the target
  requiresTargetMM: boolean; // target must be a Market Maker
}

const BOOST_CATALOGUE: Record<BoostType, BoostDef> = {
  quick_boost:     { baseCost: 80,  baseDelta: 8,   durationHours: 1,    isSelfOnly: true,  requiresTargetMM: false },
  major_boost:     { baseCost: 250, baseDelta: 20,  durationHours: 1,    isSelfOnly: true,  requiresTargetMM: false },
  spotlight_entry: { baseCost: 500, baseDelta: 0,   durationHours: 4,    isSelfOnly: true,  requiresTargetMM: false },
  instant_plus:    { baseCost: 400, baseDelta: 12,  durationHours: 1,    isSelfOnly: false, requiresTargetMM: true  },
  instant_minus:   { baseCost: 350, baseDelta: -12, durationHours: 1,    isSelfOnly: false, requiresTargetMM: true  },
  universe:        { baseCost: 800, baseDelta: 0,   durationHours: 24,   isSelfOnly: false, requiresTargetMM: true  },
  galaxy:          { baseCost: 300, baseDelta: 0,   durationHours: 24,   isSelfOnly: false, requiresTargetMM: true  },
  black_hole:      { baseCost: 250, baseDelta: 0,   durationHours: null, isSelfOnly: false, requiresTargetMM: true  },
};

const SELF_BOOST_TYPES: BoostType[] = ['quick_boost', 'major_boost', 'spotlight_entry'];

// ─────────────────────────────────────────────────────────────────────────────
// Handler
// ─────────────────────────────────────────────────────────────────────────────

Deno.serve(async (req: Request): Promise<Response> => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: CORS_HEADERS });
  }
  if (req.method !== 'POST') {
    return err('Method not allowed', 405);
  }

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
  let body: { boost_type?: string; target_user_id?: string };
  try {
    body = await req.json();
  } catch {
    return err('Invalid JSON body', 400);
  }

  const boostType = body.boost_type as BoostType | undefined;
  const targetUserId = body.target_user_id;

  if (!boostType || !BOOST_CATALOGUE[boostType]) {
    return err(`Invalid boost_type: ${boostType}`, 400);
  }
  if (!targetUserId) {
    return err('target_user_id is required', 400);
  }

  const def = BOOST_CATALOGUE[boostType];

  // ── Validate self-only constraint ─────────────────────────────────────────
  if (def.isSelfOnly && targetUserId !== user.id) {
    return err(`${boostType} can only be applied to your own profile`, 403);
  }

  // ── Load target profile ───────────────────────────────────────────────────
  const { data: targetProfile, error: profileErr } = await serviceClient
    .from('profiles')
    .select('id, is_market_maker')
    .eq('id', targetUserId)
    .single();

  if (profileErr || !targetProfile) {
    return err('Target profile not found', 404);
  }
  if (def.requiresTargetMM && !targetProfile.is_market_maker) {
    return err('Target must be a Market Maker for this boost type', 403);
  }

  // ── Black Hole: find and cancel target's active Universe ──────────────────
  if (boostType === 'black_hole') {
    const now = new Date().toISOString();
    const { data: activeUniverse } = await serviceClient
      .from('active_boosts')
      .select('id')
      .eq('target_user_id', targetUserId)
      .eq('boost_type', 'universe')
      .eq('is_cancelled', false)
      .gt('expires_at', now)
      .order('created_at', { ascending: false })
      .limit(1)
      .maybeSingle();

    if (!activeUniverse) {
      return err('Target has no active Universe to cancel', 400);
    }

    // Deduct tokens for black hole
    const { error: deductErr } = await serviceClient.rpc('increment_token_balance', {
      p_user_id: user.id,
      p_amount: -def.baseCost,
    });
    if (deductErr) return err('Insufficient token balance', 402);

    // Cancel the Universe
    await serviceClient
      .from('active_boosts')
      .update({ is_cancelled: true })
      .eq('id', activeUniverse.id);

    // Log transaction
    await serviceClient.from('token_transactions').insert({
      user_id: user.id,
      amount: -def.baseCost,
      type: 'promoted',
      description: 'Black Hole — cancelled Universe on @' + targetUserId,
      reference_id: activeUniverse.id,
    });

    // Insert black_hole record for history (no expiry)
    await serviceClient.from('active_boosts').insert({
      target_user_id: targetUserId,
      activated_by_user_id: user.id,
      boost_type: 'black_hole',
      heat_score_delta: 0,
      tokens_spent: def.baseCost,
      expires_at: null,
      is_cancelled: false,
    });

    // Trigger immediate sync for target so heat_score reflects cancellation
    await triggerSync(targetUserId);

    return ok({ tokens_spent: def.baseCost, effective_delta: 0, expires_at: null });
  }

  // ── Cooldown check (Universe / Galaxy: one active per user per target) ────
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

    if (existing) {
      return err(`You already have an active ${boostType} on this creator. Wait for it to expire.`, 409);
    }
  }

  // ── Compute effective cost and delta for self-boosts ──────────────────────
  let effectiveCost = def.baseCost;
  let effectiveDelta = def.baseDelta;

  if (SELF_BOOST_TYPES.includes(boostType)) {
    // Market Maker discount: 20% off if caller has an open market
    const { data: openMarket } = await serviceClient
      .from('markets')
      .select('id')
      .eq('creator_id', user.id)
      .eq('status', 'open')
      .limit(1)
      .maybeSingle();

    if (openMarket) {
      effectiveCost = Math.floor(effectiveCost * 0.8);
    }

    // Active market bonus: 1.5× delta if ≥200 tokens in open bets on user's market
    if (effectiveDelta > 0 && openMarket) {
      const { data: poolData } = await serviceClient
        .from('markets')
        .select('above_pool, below_pool')
        .eq('creator_id', user.id)
        .eq('status', 'open')
        .limit(1)
        .maybeSingle();

      const totalPool = (poolData?.above_pool ?? 0) + (poolData?.below_pool ?? 0);
      if (totalPool >= 200) {
        effectiveDelta = Math.round(effectiveDelta * 1.5);
      }
    }
  }

  // ── Check token balance ───────────────────────────────────────────────────
  const { data: balanceRow } = await serviceClient
    .from('token_balances')
    .select('available_tokens')
    .eq('user_id', user.id)
    .single();

  const available = (balanceRow?.available_tokens ?? 0) as number;
  if (available < effectiveCost) {
    return err(`Insufficient tokens. Need ${effectiveCost}, have ${available}.`, 402);
  }

  // ── Deduct tokens ─────────────────────────────────────────────────────────
  const { error: deductErr } = await serviceClient.rpc('increment_token_balance', {
    p_user_id: user.id,
    p_amount: -effectiveCost,
  });
  if (deductErr) {
    console.error('[apply-promotion] Token deduction failed:', deductErr);
    return err('Token deduction failed', 500);
  }

  // ── Compute expiry ────────────────────────────────────────────────────────
  let expiresAt: string | null = null;
  if (def.durationHours !== null) {
    const exp = new Date(Date.now() + def.durationHours * 60 * 60 * 1000);
    expiresAt = exp.toISOString();
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
    .select('id')
    .single();

  if (insertErr) {
    console.error('[apply-promotion] Insert boost failed:', insertErr);
    // Refund tokens since insert failed
    await serviceClient.rpc('increment_token_balance', {
      p_user_id: user.id,
      p_amount: effectiveCost,
    });
    return err('Failed to apply boost. Tokens have been refunded.', 500);
  }

  // ── Log token transaction ─────────────────────────────────────────────────
  const descriptionMap: Record<BoostType, string> = {
    quick_boost:     `Quick Boost — +${effectiveDelta} heat for 1h`,
    major_boost:     `Major Boost — +${effectiveDelta} heat for 1h`,
    spotlight_entry: 'Spotlight Entry — guaranteed slot for 4h',
    instant_plus:    `+Popularity — +${effectiveDelta} heat for 1h`,
    instant_minus:   `-Popularity — ${effectiveDelta} heat for 1h`,
    universe:        'Universe — global animation for 24h',
    galaxy:          'Galaxy — name highlight for 24h',
    black_hole:      'Black Hole — cancelled Universe',
  };

  await serviceClient.from('token_transactions').insert({
    user_id: user.id,
    amount: -effectiveCost,
    type: 'promoted',
    description: descriptionMap[boostType],
    reference_id: boostRow.id,
  });

  // ── Trigger immediate sync for target ─────────────────────────────────────
  // Fire-and-forget — don't await so response is fast
  triggerSync(targetUserId).catch((e) =>
    console.error('[apply-promotion] Sync trigger failed:', e),
  );

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
