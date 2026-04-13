class ActiveBoost {
  final String id;
  final String targetUserId;
  final String activatedByUserId;
  final String boostType;
  final double heatScoreDelta;
  final int tokensSpent;
  final DateTime? expiresAt;
  final bool isCancelled;
  final DateTime createdAt;

  const ActiveBoost({
    required this.id,
    required this.targetUserId,
    required this.activatedByUserId,
    required this.boostType,
    required this.heatScoreDelta,
    required this.tokensSpent,
    this.expiresAt,
    required this.isCancelled,
    required this.createdAt,
  });

  factory ActiveBoost.fromJson(Map<String, dynamic> json) => ActiveBoost(
        id: json['id'] as String,
        targetUserId: json['target_user_id'] as String,
        activatedByUserId: json['activated_by_user_id'] as String,
        boostType: json['boost_type'] as String,
        heatScoreDelta: (json['heat_score_delta'] as num?)?.toDouble() ?? 0.0,
        tokensSpent: (json['tokens_spent'] as num).toInt(),
        expiresAt: json['expires_at'] != null
            ? DateTime.parse(json['expires_at'] as String)
            : null,
        isCancelled: json['is_cancelled'] as bool? ?? false,
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  bool get isActive {
    if (isCancelled) return false;
    if (expiresAt == null) return false; // instant effects (black_hole) are never "active"
    return expiresAt!.isAfter(DateTime.now());
  }

  Duration? get remaining {
    if (!isActive) return null;
    return expiresAt!.difference(DateTime.now());
  }
}
