import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/challenge_models.dart';

// ─────────────────────────────────────────────────────────────────────────────
// userBadgesProvider(userId)
// Returns all earned badges for a given user, joined with their definitions.
// Public: any user's badges can be viewed (badges are not sensitive).
// ─────────────────────────────────────────────────────────────────────────────

final userBadgesProvider = FutureProvider.autoDispose
    .family<List<UserBadge>, String>((ref, userId) async {
  final data = await Supabase.instance.client
      .from('user_badges')
      .select(
        'id, user_id, badge_id, challenge_id, awarded_at, '
        'badge_definitions(id, slug, name, description, tier, condition_type, pool, passive_effect)',
      )
      .eq('user_id', userId)
      .order('awarded_at', ascending: false);

  return (data as List).map((row) {
    final defJson =
        Map<String, dynamic>.from(row['badge_definitions'] as Map);
    final def = BadgeDefinition.fromJson(defJson);
    return UserBadge.fromJson(Map<String, dynamic>.from(row as Map), def);
  }).toList();
});

// ─────────────────────────────────────────────────────────────────────────────
// allChallengesProvider
// All active non-once challenge definitions (for the challenges screen).
// ─────────────────────────────────────────────────────────────────────────────

final allChallengesProvider =
    FutureProvider.autoDispose<List<ChallengeDefinition>>((ref) async {
  final data = await Supabase.instance.client
      .from('challenge_definitions')
      .select('id, slug, badge_id, track, condition, token_reward, pool')
      .eq('is_active', true)
      .inFilter('track', ['daily', 'weekly', 'monthly'])
      .order('track');

  return (data as List)
      .map((e) => ChallengeDefinition.fromJson(e as Map<String, dynamic>))
      .toList();
});

// ─────────────────────────────────────────────────────────────────────────────
// challengeProgressProvider
// Current period's progress rows for the logged-in user.
// Queries all three period keys at once.
// ─────────────────────────────────────────────────────────────────────────────

final challengeProgressProvider =
    FutureProvider.autoDispose<List<ChallengeProgress>>((ref) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return [];

  final dailyKey = periodKey('daily');
  final weeklyKey = periodKey('weekly');
  final monthlyKey = periodKey('monthly');

  final data = await Supabase.instance.client
      .from('user_challenge_progress')
      .select(
          'id, challenge_id, period_key, current_count, completed_at, tokens_awarded')
      .eq('user_id', userId)
      .or('period_key.eq.$dailyKey,period_key.eq.$weeklyKey,period_key.eq.$monthlyKey');

  return (data as List)
      .map((e) => ChallengeProgress.fromJson(e as Map<String, dynamic>))
      .toList();
});

// ─────────────────────────────────────────────────────────────────────────────
// passiveEffectsProvider(userId)
// Reads the user_passive_effects view for aggregated badge passive effects.
// ─────────────────────────────────────────────────────────────────────────────

final passiveEffectsProvider = FutureProvider.autoDispose
    .family<PassiveEffects, String>((ref, userId) async {
  final data = await Supabase.instance.client
      .from('user_passive_effects')
      .select(
          'visibility_multiplier, token_earn_rate, promotion_discount, '
          'referral_bonus_tokens, referral_bonus_after_n')
      .eq('user_id', userId)
      .maybeSingle();

  if (data == null) return PassiveEffects.empty;
  return PassiveEffects.fromJson(data);
});

// ─────────────────────────────────────────────────────────────────────────────
// ChallengeActions
// Fire-and-forget calls to the evaluate-challenges edge function.
// Uses the Supabase client's built-in functions.invoke() which automatically
// attaches the current user's JWT.
// ─────────────────────────────────────────────────────────────────────────────

class ChallengeActions {
  final _client = Supabase.instance.client;

  /// Fire daily check-in. Evaluates daily_check_in challenge + snapshot
  /// challenges (OG, Early Adopter) on first call of the day.
  Future<void> fireCheckIn() async {
    try {
      await _client.functions.invoke(
        'evaluate-challenges',
        body: {'event': 'check_in', 'metadata': {}},
      );
    } catch (_) {
      // Fire-and-forget: swallow errors silently
    }
  }

  /// Fire when a bet is placed. Covers daily_place_bet and
  /// weekly_bet_3_makers challenges.
  /// [creatorId] is the Market Maker's user ID.
  Future<void> fireBetPlaced(String creatorId) async {
    try {
      await _client.functions.invoke(
        'evaluate-challenges',
        body: {
          'event': 'bet_placed',
          'metadata': {'creator_id': creatorId},
        },
      );
      // Also fire the unique-MM variant for weekly_bet_3_makers
      await _client.functions.invoke(
        'evaluate-challenges',
        body: {
          'event': 'bet_placed_unique_mm',
          'metadata': {'creator_id': creatorId},
        },
      );
    } catch (_) {
      // Fire-and-forget
    }
  }

  /// Fire after signup completes when a referral code was used.
  /// The edge function reads the new user's referred_by field and
  /// awards the challenge to the referrer.
  Future<void> fireReferralSignup() async {
    try {
      await _client.functions.invoke(
        'evaluate-challenges',
        body: {'event': 'referral_signup', 'metadata': {}},
      );
    } catch (_) {
      // Fire-and-forget
    }
  }
}

final challengeActionsProvider =
    Provider<ChallengeActions>((ref) => ChallengeActions());
