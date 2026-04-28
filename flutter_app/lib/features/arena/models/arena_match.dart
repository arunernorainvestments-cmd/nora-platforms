class ArenaMatch {
  final String id;
  final int round;
  final String state; // 'pending' | 'pre_match' | 'live' | 'resolved'
  final String player1Id;
  final String player2Id;
  final String player1Username;
  final String player2Username;
  final String? player1Category;
  final String? player2Category;
  final String player1Archetype;
  final String player2Archetype;
  final DateTime scheduledStart;
  final DateTime? actualStart;
  final DateTime? actualEnd;
  final String? winnerId;
  final double? finalScoreP1;
  final double? finalScoreP2;
  final DateTime createdAt;

  const ArenaMatch({
    required this.id,
    required this.round,
    required this.state,
    required this.player1Id,
    required this.player2Id,
    required this.player1Username,
    required this.player2Username,
    this.player1Category,
    this.player2Category,
    required this.player1Archetype,
    required this.player2Archetype,
    required this.scheduledStart,
    this.actualStart,
    this.actualEnd,
    this.winnerId,
    this.finalScoreP1,
    this.finalScoreP2,
    required this.createdAt,
  });

  bool get isPreMatch => state == 'pre_match';
  bool get isLive => state == 'live';
  bool get isResolved => state == 'resolved';

  Duration get timeUntilStart =>
      scheduledStart.difference(DateTime.now().toUtc());

  Duration get timeRemaining {
    if (actualStart == null) return Duration.zero;
    final end = actualStart!.add(const Duration(minutes: 5));
    final remaining = end.difference(DateTime.now().toUtc());
    return remaining.isNegative ? Duration.zero : remaining;
  }

  factory ArenaMatch.fromJson(Map<String, dynamic> json) {
    final p1 = json['player_1'] as Map<String, dynamic>? ?? {};
    final p2 = json['player_2'] as Map<String, dynamic>? ?? {};
    return ArenaMatch(
      id: json['id'] as String,
      round: (json['round'] as num).toInt(),
      state: json['state'] as String,
      player1Id: json['player_1_id'] as String,
      player2Id: json['player_2_id'] as String,
      player1Username: p1['username'] as String? ?? 'Player 1',
      player2Username: p2['username'] as String? ?? 'Player 2',
      player1Category: p1['category_1'] as String?,
      player2Category: p2['category_1'] as String?,
      player1Archetype: json['player_1_archetype'] as String,
      player2Archetype: json['player_2_archetype'] as String,
      scheduledStart: DateTime.parse(json['scheduled_start'] as String),
      actualStart: json['actual_start'] != null
          ? DateTime.parse(json['actual_start'] as String)
          : null,
      actualEnd: json['actual_end'] != null
          ? DateTime.parse(json['actual_end'] as String)
          : null,
      winnerId: json['winner_id'] as String?,
      finalScoreP1: (json['final_score_p1'] as num?)?.toDouble(),
      finalScoreP2: (json['final_score_p2'] as num?)?.toDouble(),
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}
