import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/active_boost.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Active boosts for a given user (read from DB — only visible to activator/target)
// ─────────────────────────────────────────────────────────────────────────────

final activeBoostsProvider = FutureProvider.autoDispose
    .family<List<ActiveBoost>, String>((ref, targetUserId) async {
  final now = DateTime.now().toIso8601String();
  final data = await Supabase.instance.client
      .from('active_boosts')
      .select(
        'id, target_user_id, activated_by_user_id, boost_type, '
        'heat_score_delta, tokens_spent, expires_at, is_cancelled, created_at',
      )
      .eq('target_user_id', targetUserId)
      .eq('is_cancelled', false)
      .or('expires_at.is.null,expires_at.gt.$now')
      .order('created_at', ascending: false);

  return (data as List)
      .map((e) => ActiveBoost.fromJson(e as Map<String, dynamic>))
      .toList();
});

// ─────────────────────────────────────────────────────────────────────────────
// Promotion context for self-boosts: discount + multiplier eligibility
// ─────────────────────────────────────────────────────────────────────────────

class PromotionContext {
  /// 20% off if the user has an open market.
  final bool hasMarketMakerDiscount;

  /// 1.5× heat delta if ≥200 tokens in open bets on their market.
  final bool hasActiveBetMultiplier;

  const PromotionContext({
    required this.hasMarketMakerDiscount,
    required this.hasActiveBetMultiplier,
  });
}

final promotionContextProvider =
    FutureProvider.autoDispose<PromotionContext>((ref) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) {
    return const PromotionContext(
      hasMarketMakerDiscount: false,
      hasActiveBetMultiplier: false,
    );
  }

  final data = await Supabase.instance.client
      .from('markets')
      .select('id, above_pool, below_pool')
      .eq('creator_id', userId)
      .eq('status', 'open')
      .limit(1)
      .maybeSingle();

  if (data == null) {
    return const PromotionContext(
      hasMarketMakerDiscount: false,
      hasActiveBetMultiplier: false,
    );
  }

  final pool =
      (data['above_pool'] as num? ?? 0) + (data['below_pool'] as num? ?? 0);

  return PromotionContext(
    hasMarketMakerDiscount: true,
    hasActiveBetMultiplier: pool >= 200,
  );
});

// ─────────────────────────────────────────────────────────────────────────────
// Helpers: compute effective cost and delta given context
// ─────────────────────────────────────────────────────────────────────────────

int effectiveCost(int baseCost, {required bool hasMakerDiscount}) {
  if (hasMakerDiscount) return (baseCost * 0.8).floor();
  return baseCost;
}

int effectiveDelta(int baseDelta, {required bool hasMultiplier}) {
  if (hasMultiplier && baseDelta > 0) return (baseDelta * 1.5).round();
  return baseDelta;
}
