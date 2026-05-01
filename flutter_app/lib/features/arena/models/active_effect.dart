class ActiveEffect {
  final String effectId;
  final String abilityId;
  final String? sourceUserId;
  final int targetPlayer; // 1 or 2
  final String modifier;
  final double value;
  final DateTime? expiresAt;
  final bool isPassive;

  const ActiveEffect({
    required this.effectId,
    required this.abilityId,
    this.sourceUserId,
    required this.targetPlayer,
    required this.modifier,
    required this.value,
    this.expiresAt,
    required this.isPassive,
  });

  bool get isExpired =>
      expiresAt != null && expiresAt!.isBefore(DateTime.now().toUtc());

  Duration get remaining {
    if (expiresAt == null) return Duration.zero;
    final r = expiresAt!.difference(DateTime.now().toUtc());
    return r.isNegative ? Duration.zero : r;
  }

  factory ActiveEffect.fromJson(Map<String, dynamic> json) {
    return ActiveEffect(
      effectId:     json['effect_id'] as String,
      abilityId:    json['ability_id'] as String,
      sourceUserId: json['source_user_id'] as String?,
      targetPlayer: (json['target_player'] as num).toInt(),
      modifier:     json['modifier'] as String,
      value:        (json['value'] as num).toDouble(),
      expiresAt:    json['expires_at'] != null
          ? DateTime.parse(json['expires_at'] as String)
          : null,
      isPassive: (json['is_passive'] as bool?) ?? false,
    );
  }
}
