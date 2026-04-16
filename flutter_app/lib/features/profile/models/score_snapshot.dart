class ScoreSnapshot {
  final int compositeScore;
  final DateTime recordedAt;

  const ScoreSnapshot({
    required this.compositeScore,
    required this.recordedAt,
  });

  factory ScoreSnapshot.fromJson(Map<String, dynamic> json) {
    return ScoreSnapshot(
      compositeScore: (json['composite_score'] as num?)?.toInt() ?? 0,
      recordedAt: DateTime.parse(json['recorded_at'] as String),
    );
  }
}
