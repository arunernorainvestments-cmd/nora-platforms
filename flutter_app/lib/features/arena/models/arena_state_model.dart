class ArenaStateModel {
  final String matchId;
  final int tick;
  final double scoreP1;
  final double scoreP2;
  final double flowRateP1;
  final double flowRateP2;
  final double heatInfluenceP1;
  final double heatInfluenceP2;
  final double suppressionP1;
  final double suppressionP2;
  final double totalPoolP1;
  final double totalPoolP2;
  final DateTime updatedAt;

  const ArenaStateModel({
    required this.matchId,
    required this.tick,
    required this.scoreP1,
    required this.scoreP2,
    required this.flowRateP1,
    required this.flowRateP2,
    required this.heatInfluenceP1,
    required this.heatInfluenceP2,
    required this.suppressionP1,
    required this.suppressionP2,
    required this.totalPoolP1,
    required this.totalPoolP2,
    required this.updatedAt,
  });

  double get totalScore => scoreP1 + scoreP2;
  double get totalPool  => totalPoolP1 + totalPoolP2;

  // Returns 0.5 when both scores are zero to avoid division-by-zero.
  double get fractionP1 => totalScore == 0 ? 0.5 : scoreP1 / totalScore;
  double get fractionP2 => totalScore == 0 ? 0.5 : scoreP2 / totalScore;

  int get percentP1 => (fractionP1 * 100).round();
  int get percentP2 => (fractionP2 * 100).round();

  factory ArenaStateModel.fromJson(Map<String, dynamic> json) {
    return ArenaStateModel(
      matchId:          json['match_id'] as String,
      tick:             (json['tick'] as num).toInt(),
      scoreP1:          (json['score_p1'] as num?)?.toDouble() ?? 0,
      scoreP2:          (json['score_p2'] as num?)?.toDouble() ?? 0,
      flowRateP1:       (json['flow_rate_p1'] as num?)?.toDouble() ?? 0,
      flowRateP2:       (json['flow_rate_p2'] as num?)?.toDouble() ?? 0,
      heatInfluenceP1:  (json['heat_influence_p1'] as num?)?.toDouble() ?? 0,
      heatInfluenceP2:  (json['heat_influence_p2'] as num?)?.toDouble() ?? 0,
      suppressionP1:    (json['suppression_p1'] as num?)?.toDouble() ?? 0,
      suppressionP2:    (json['suppression_p2'] as num?)?.toDouble() ?? 0,
      totalPoolP1:      (json['total_pool_p1'] as num?)?.toDouble() ?? 0,
      totalPoolP2:      (json['total_pool_p2'] as num?)?.toDouble() ?? 0,
      updatedAt:        DateTime.parse(json['updated_at'] as String),
    );
  }

  static ArenaStateModel empty(String matchId) => ArenaStateModel(
    matchId:          matchId,
    tick:             0,
    scoreP1:          0,
    scoreP2:          0,
    flowRateP1:       0,
    flowRateP2:       0,
    heatInfluenceP1:  0,
    heatInfluenceP2:  0,
    suppressionP1:    0,
    suppressionP2:    0,
    totalPoolP1:      0,
    totalPoolP2:      0,
    updatedAt:        DateTime.now().toUtc(),
  );
}
