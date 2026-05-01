class ArenaEvent {
  final String id;
  final String matchId;
  final String userId;
  final String targetId;
  final String type; // 'back' | 'trigger'
  final double value;
  final Map<String, dynamic> metadata;
  final DateTime createdAt;

  const ArenaEvent({
    required this.id,
    required this.matchId,
    required this.userId,
    required this.targetId,
    required this.type,
    required this.value,
    required this.metadata,
    required this.createdAt,
  });

  // For trigger events: the ability display name from metadata
  String? get abilityDisplayName => metadata['display_name'] as String?;

  factory ArenaEvent.fromJson(Map<String, dynamic> json) {
    return ArenaEvent(
      id:        json['id'] as String,
      matchId:   json['match_id'] as String,
      userId:    json['user_id'] as String,
      targetId:  json['target_id'] as String,
      type:      json['type'] as String,
      value:     (json['value'] as num).toDouble(),
      metadata:  (json['metadata'] as Map<String, dynamic>?) ?? {},
      createdAt: DateTime.parse(json['created_at'] as String),
    );
  }
}
