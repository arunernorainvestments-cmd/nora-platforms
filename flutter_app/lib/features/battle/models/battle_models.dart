// Likeness-card stat sheets (cosmetic under v3 — Likeness Cards system).
// The rest of the legacy 1v1 fighter models (BattleMatch/BattleParticipant/
// AbilityData/EligibleCharacter) were removed with the legacy web battle client
// (2026-07-12 crossplay pass); the v3 card-battler models live in
// providers/spectate_providers.dart (Ccg*).

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
        effectiveResilience:
            (json['effective_resilience'] as num?)?.toInt() ?? 50,
        effectiveAgility: (json['effective_agility'] as num?)?.toInt() ?? 50,
        effectiveWit: (json['effective_wit'] as num?)?.toInt() ?? 50,
        effectiveInfluence:
            (json['effective_influence'] as num?)?.toInt() ?? 50,
        weeklyPollMultiplier:
            (json['weekly_poll_multiplier'] as num?)?.toDouble() ?? 1.0,
      );
}
