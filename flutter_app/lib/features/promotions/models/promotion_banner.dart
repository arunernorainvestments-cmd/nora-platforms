class PromotionBanner {
  final String id;
  final String type; // 'universe' | 'galaxy'
  final String targetUserId;
  final String targetUsername;
  final String? category; // galaxy only
  final DateTime expiresAt;
  final bool isCancelled;
  final DateTime createdAt;

  const PromotionBanner({
    required this.id,
    required this.type,
    required this.targetUserId,
    required this.targetUsername,
    this.category,
    required this.expiresAt,
    required this.isCancelled,
    required this.createdAt,
  });

  factory PromotionBanner.fromJson(Map<String, dynamic> json) => PromotionBanner(
        id: json['id'] as String,
        type: json['type'] as String,
        targetUserId: json['target_user_id'] as String,
        targetUsername: json['target_username'] as String,
        category: json['category'] as String?,
        expiresAt: DateTime.parse(json['expires_at'] as String),
        isCancelled: json['is_cancelled'] as bool? ?? false,
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  bool get isActive => !isCancelled && expiresAt.isAfter(DateTime.now());

  bool get isUniverse => type == 'universe';
  bool get isGalaxy => type == 'galaxy';

  String get emoji => isUniverse ? '🌌' : '🌠';

  String get tickerLabel => isUniverse
      ? '$emoji Universe: @$targetUsername is on fire!'
      : '$emoji Galaxy: @$targetUsername in $category';
}
