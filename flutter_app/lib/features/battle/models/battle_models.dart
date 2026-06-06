class AbilityData {
  // id is null for placeholder/test data; populated from battle_abilities DB rows.
  final String? id;
  final int slot;
  final String name;
  final int apCost;
  // TODO(Phase C): source from battle_abilities table
  final int damage;
  final bool requiresMomentum;

  const AbilityData({
    this.id,
    required this.slot,
    required this.name,
    required this.apCost,
    required this.damage,
    this.requiresMomentum = false,
  });

  factory AbilityData.fromJson(Map<String, dynamic> json) => AbilityData(
        id: json['id'] as String?,
        slot: json['ability_slot'] as int,
        name: json['name'] as String,
        apCost: json['ap_cost'] as int,
        damage: json['base_damage'] as int? ?? 0,
        requiresMomentum: json['requires_momentum'] as bool? ?? false,
      );
}

class BenchCharacter {
  final String archetype;
  final String displayName;
  final int currentHp;
  final int maxHp;
  final bool isKO;

  const BenchCharacter({
    required this.archetype,
    required this.displayName,
    required this.currentHp,
    required this.maxHp,
    this.isKO = false,
  });
}

class BattleMatch {
  final String id;
  final String lobbyCode;
  final String status;
  final String hostUserId;
  final int currentTurn;
  final DateTime? turnDeadline;
  final int? winnerTeamNumber;

  const BattleMatch({
    required this.id,
    required this.lobbyCode,
    required this.status,
    required this.hostUserId,
    required this.currentTurn,
    this.turnDeadline,
    this.winnerTeamNumber,
  });

  factory BattleMatch.fromJson(Map<String, dynamic> json) => BattleMatch(
        id: json['id'] as String,
        lobbyCode: json['lobby_code'] as String,
        status: json['status'] as String,
        hostUserId: json['host_user_id'] as String,
        currentTurn: json['current_turn'] as int? ?? 0,
        turnDeadline: json['turn_deadline'] != null
            ? DateTime.parse(json['turn_deadline'] as String).toLocal()
            : null,
        winnerTeamNumber: json['winner_team_number'] as int?,
      );
}

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
}

class EligibleCharacter {
  final String creatorId;
  final String characterName;
  final String archetype;
  final String? characterImageUrl;
  final String eligibilityType;
  final String? cardId;
  final int? cardNumber;
  final String? rarity;
  final int statPower;
  final int statCharisma;
  final int statResilience;
  final int statAgility;
  final int statWit;
  final int statInfluence;

  const EligibleCharacter({
    required this.creatorId,
    required this.characterName,
    required this.archetype,
    this.characterImageUrl,
    required this.eligibilityType,
    this.cardId,
    this.cardNumber,
    this.rarity,
    required this.statPower,
    required this.statCharisma,
    required this.statResilience,
    required this.statAgility,
    required this.statWit,
    required this.statInfluence,
  });

  factory EligibleCharacter.fromJson(Map<String, dynamic> json) =>
      EligibleCharacter(
        creatorId: json['creator_id'] as String,
        characterName: json['character_name'] as String,
        archetype: json['archetype'] as String,
        characterImageUrl: json['character_image_url'] as String?,
        eligibilityType: json['eligibility_type'] as String? ?? 'self',
        cardId: json['card_id'] as String?,
        cardNumber: (json['card_number'] as num?)?.toInt(),
        rarity: json['rarity'] as String?,
        statPower: (json['stat_power'] as num?)?.toInt() ?? 50,
        statCharisma: (json['stat_charisma'] as num?)?.toInt() ?? 50,
        statResilience: (json['stat_resilience'] as num?)?.toInt() ?? 50,
        statAgility: (json['stat_agility'] as num?)?.toInt() ?? 50,
        statWit: (json['stat_wit'] as num?)?.toInt() ?? 50,
        statInfluence: (json['stat_influence'] as num?)?.toInt() ?? 50,
      );
}

class BattleParticipant {
  final String id;
  final String matchId;
  final String userId;
  final int teamNumber;
  final int slotPosition;
  final String archetype;
  final String characterName;
  final int maxHp;
  final int currentHp;
  final int maxAp;
  final int currentAp;
  final int momentum;
  final bool isActive;
  final bool isFainted;

  const BattleParticipant({
    required this.id,
    required this.matchId,
    required this.userId,
    required this.teamNumber,
    required this.slotPosition,
    required this.archetype,
    required this.characterName,
    required this.maxHp,
    required this.currentHp,
    required this.maxAp,
    required this.currentAp,
    required this.momentum,
    required this.isActive,
    required this.isFainted,
  });

  factory BattleParticipant.fromJson(Map<String, dynamic> json) => BattleParticipant(
        id: json['id'] as String,
        matchId: json['match_id'] as String,
        userId: json['user_id'] as String,
        teamNumber: json['team_number'] as int,
        slotPosition: json['slot_position'] as int,
        archetype: json['archetype'] as String,
        characterName: json['character_name'] as String,
        maxHp: json['max_hp'] as int,
        currentHp: json['current_hp'] as int,
        maxAp: json['max_ap'] as int,
        currentAp: json['current_ap'] as int,
        momentum: json['momentum'] as int? ?? 0,
        isActive: json['is_active'] as bool? ?? false,
        isFainted: json['is_fainted'] as bool? ?? false,
      );
}
