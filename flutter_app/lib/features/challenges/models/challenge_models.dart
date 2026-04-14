import 'package:intl/intl.dart';

// ─────────────────────────────────────────────────────────────────────────────
// BadgeDefinition
// ─────────────────────────────────────────────────────────────────────────────

class BadgeDefinition {
  final String id;
  final String slug;
  final String name;
  final String description;
  final String tier; // 'bronze' | 'silver' | 'gold'
  final String conditionType;
  final String pool; // 'all' | 'mm'
  final Map<String, dynamic>? passiveEffect;

  const BadgeDefinition({
    required this.id,
    required this.slug,
    required this.name,
    required this.description,
    required this.tier,
    required this.conditionType,
    required this.pool,
    this.passiveEffect,
  });

  factory BadgeDefinition.fromJson(Map<String, dynamic> json) => BadgeDefinition(
        id: json['id'] as String,
        slug: json['slug'] as String,
        name: json['name'] as String,
        description: json['description'] as String,
        tier: json['tier'] as String,
        conditionType: json['condition_type'] as String,
        pool: json['pool'] as String? ?? 'all',
        passiveEffect: json['passive_effect'] as Map<String, dynamic>?,
      );

  /// Human-readable description of the passive effect, if any.
  String? get passiveEffectLabel {
    final effect = passiveEffect;
    if (effect == null) return null;
    final type = effect['type'] as String?;
    switch (type) {
      case 'visibility_multiplier':
        final pct = ((effect['value'] as num) * 100).toStringAsFixed(0);
        return '+$pct% feed visibility';
      case 'token_earn_rate':
        final pct = ((effect['value'] as num) * 100).toStringAsFixed(0);
        return '+$pct% token earnings';
      case 'promotion_discount':
        final pct = ((effect['value'] as num) * 100).toStringAsFixed(0);
        return '$pct% off promotions';
      case 'referral_bonus':
        final tokens = effect['bonus_tokens'] as int?;
        return '+$tokens bonus tokens per referral';
      default:
        return null;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// UserBadge
// ─────────────────────────────────────────────────────────────────────────────

class UserBadge {
  final String id;
  final String userId;
  final String badgeId;
  final String? challengeId;
  final DateTime awardedAt;
  final BadgeDefinition definition;

  const UserBadge({
    required this.id,
    required this.userId,
    required this.badgeId,
    this.challengeId,
    required this.awardedAt,
    required this.definition,
  });

  factory UserBadge.fromJson(
    Map<String, dynamic> json,
    BadgeDefinition definition,
  ) =>
      UserBadge(
        id: json['id'] as String,
        userId: json['user_id'] as String,
        badgeId: json['badge_id'] as String,
        challengeId: json['challenge_id'] as String?,
        awardedAt: DateTime.parse(json['awarded_at'] as String),
        definition: definition,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// ChallengeDefinition
// ─────────────────────────────────────────────────────────────────────────────

class ChallengeDefinition {
  final String id;
  final String slug;
  final String? badgeId;
  final String track; // 'daily' | 'weekly' | 'monthly' | 'once'
  final Map<String, dynamic> condition;
  final int tokenReward;
  final String pool;

  const ChallengeDefinition({
    required this.id,
    required this.slug,
    this.badgeId,
    required this.track,
    required this.condition,
    required this.tokenReward,
    required this.pool,
  });

  factory ChallengeDefinition.fromJson(Map<String, dynamic> json) =>
      ChallengeDefinition(
        id: json['id'] as String,
        slug: json['slug'] as String,
        badgeId: json['badge_id'] as String?,
        track: json['track'] as String,
        condition: Map<String, dynamic>.from(json['condition'] as Map),
        tokenReward: (json['token_reward'] as num?)?.toInt() ?? 0,
        pool: json['pool'] as String? ?? 'all',
      );

  /// Human-readable name derived from the slug.
  String get displayName {
    // Convert slug like 'daily_place_bet' → 'Place a Bet'
    final parts = slug.split('_');
    // Drop track prefix (daily_, weekly_, monthly_, earn_, once_)
    final relevant = parts.length > 1 ? parts.sublist(1) : parts;
    return relevant
        .map((w) => w[0].toUpperCase() + w.substring(1))
        .join(' ');
  }

  /// The count required to complete this challenge.
  int get requiredCount => (condition['count'] as num?)?.toInt() ?? 1;
}

// ─────────────────────────────────────────────────────────────────────────────
// ChallengeProgress
// ─────────────────────────────────────────────────────────────────────────────

class ChallengeProgress {
  final String id;
  final String challengeId;
  final String periodKey;
  final int currentCount;
  final DateTime? completedAt;
  final bool tokensAwarded;

  const ChallengeProgress({
    required this.id,
    required this.challengeId,
    required this.periodKey,
    required this.currentCount,
    this.completedAt,
    required this.tokensAwarded,
  });

  bool get isCompleted => completedAt != null;

  factory ChallengeProgress.fromJson(Map<String, dynamic> json) =>
      ChallengeProgress(
        id: json['id'] as String,
        challengeId: json['challenge_id'] as String,
        periodKey: json['period_key'] as String,
        currentCount: (json['current_count'] as num?)?.toInt() ?? 0,
        completedAt: json['completed_at'] != null
            ? DateTime.parse(json['completed_at'] as String)
            : null,
        tokensAwarded: json['tokens_awarded'] as bool? ?? false,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// PassiveEffects
// ─────────────────────────────────────────────────────────────────────────────

class PassiveEffects {
  final double visibilityMultiplier;
  final double tokenEarnRate;
  final double promotionDiscount;
  final int referralBonusTokens;
  final int referralBonusAfterN;

  const PassiveEffects({
    this.visibilityMultiplier = 0,
    this.tokenEarnRate = 0,
    this.promotionDiscount = 0,
    this.referralBonusTokens = 0,
    this.referralBonusAfterN = 0,
  });

  static const PassiveEffects empty = PassiveEffects();

  factory PassiveEffects.fromJson(Map<String, dynamic> json) => PassiveEffects(
        visibilityMultiplier:
            (json['visibility_multiplier'] as num?)?.toDouble() ?? 0,
        tokenEarnRate: (json['token_earn_rate'] as num?)?.toDouble() ?? 0,
        promotionDiscount:
            (json['promotion_discount'] as num?)?.toDouble() ?? 0,
        referralBonusTokens:
            (json['referral_bonus_tokens'] as num?)?.toInt() ?? 0,
        referralBonusAfterN:
            (json['referral_bonus_after_n'] as num?)?.toInt() ?? 0,
      );

  bool get hasAny =>
      visibilityMultiplier > 0 ||
      tokenEarnRate > 0 ||
      promotionDiscount > 0 ||
      referralBonusTokens > 0;
}

// ─────────────────────────────────────────────────────────────────────────────
// Period key helper (mirrors the edge function logic)
// ─────────────────────────────────────────────────────────────────────────────

String periodKey(String track) {
  final now = DateTime.now().toUtc();
  switch (track) {
    case 'daily':
      return DateFormat('yyyy-MM-dd').format(now);
    case 'weekly':
      return _isoWeekKey(now);
    case 'monthly':
      return DateFormat('yyyy-MM').format(now);
    case 'once':
    default:
      return 'once';
  }
}

String _isoWeekKey(DateTime dt) {
  // ISO 8601 week: week 1 contains the first Thursday of the year.
  final d = DateTime.utc(dt.year, dt.month, dt.day);
  final dayOfWeek = d.weekday; // 1=Mon … 7=Sun
  final thursday = d.add(Duration(days: 4 - dayOfWeek));
  final yearStart = DateTime.utc(thursday.year, 1, 1);
  final weekNo =
      ((thursday.difference(yearStart).inDays) / 7).floor() + 1;
  return '${thursday.year}-W${weekNo.toString().padLeft(2, '0')}';
}
