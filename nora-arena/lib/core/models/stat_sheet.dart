// SHARED MODEL — keep in sync with nora-platforms/lib/features/battle/models/battle_models.dart (StatSheet)
// Source table: creator_stat_sheets (migration 080). PK = user_id.

class StatSheet {
  final String userId;
  final int statPower;
  final int statCharisma;
  final int statResilience;
  final int statAgility;
  final int statWit;
  final int statInfluence;
  final int effectivePower;
  final int effectiveCharisma;
  final int effectiveResilience;
  final int effectiveAgility;
  final int effectiveWit;
  final int effectiveInfluence;
  final double weeklyPollMultiplier;

  const StatSheet({
    required this.userId,
    required this.statPower,
    required this.statCharisma,
    required this.statResilience,
    required this.statAgility,
    required this.statWit,
    required this.statInfluence,
    required this.effectivePower,
    required this.effectiveCharisma,
    required this.effectiveResilience,
    required this.effectiveAgility,
    required this.effectiveWit,
    required this.effectiveInfluence,
    required this.weeklyPollMultiplier,
  });

  factory StatSheet.fromJson(Map<String, dynamic> json) => StatSheet(
        userId: json['user_id'] as String,
        statPower: (json['stat_power'] as num?)?.toInt() ?? 50,
        statCharisma: (json['stat_charisma'] as num?)?.toInt() ?? 50,
        statResilience: (json['stat_resilience'] as num?)?.toInt() ?? 50,
        statAgility: (json['stat_agility'] as num?)?.toInt() ?? 50,
        statWit: (json['stat_wit'] as num?)?.toInt() ?? 50,
        statInfluence: (json['stat_influence'] as num?)?.toInt() ?? 50,
        effectivePower: (json['effective_power'] as num?)?.toInt() ?? 50,
        effectiveCharisma: (json['effective_charisma'] as num?)?.toInt() ?? 50,
        effectiveResilience: (json['effective_resilience'] as num?)?.toInt() ?? 50,
        effectiveAgility: (json['effective_agility'] as num?)?.toInt() ?? 50,
        effectiveWit: (json['effective_wit'] as num?)?.toInt() ?? 50,
        effectiveInfluence: (json['effective_influence'] as num?)?.toInt() ?? 50,
        weeklyPollMultiplier:
            (json['weekly_poll_multiplier'] as num?)?.toDouble() ?? 1.0,
      );

  /// The dominant effective stat — used to pick a battle archetype rig when the
  /// creator has no explicit archetype assigned.
  String get dominantStat {
    final entries = <String, int>{
      'power': effectivePower,
      'charisma': effectiveCharisma,
      'resilience': effectiveResilience,
      'agility': effectiveAgility,
      'wit': effectiveWit,
      'influence': effectiveInfluence,
    };
    return entries.entries.reduce((a, b) => a.value >= b.value ? a : b).key;
  }
}
