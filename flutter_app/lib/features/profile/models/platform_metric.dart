class PlatformMetric {
  final String userId;
  final String platform;
  final bool isLive;
  final int liveViewerCount;
  final int followerCount;
  final String? streamTitle;
  final String? streamCategory;
  final int displayScore;
  final double heatScore;
  final String? platformUsername;

  const PlatformMetric({
    required this.userId,
    required this.platform,
    required this.isLive,
    required this.liveViewerCount,
    required this.followerCount,
    this.streamTitle,
    this.streamCategory,
    required this.displayScore,
    this.heatScore = 0.0,
    this.platformUsername,
  });

  factory PlatformMetric.fromJson(Map<String, dynamic> json) {
    final conn = json['platform_connections'] as Map<String, dynamic>?;
    return PlatformMetric(
      userId: json['user_id'] as String? ?? '',
      platform: json['platform'] as String,
      isLive: json['is_live'] as bool? ?? false,
      liveViewerCount: (json['live_viewer_count'] as num?)?.toInt() ?? 0,
      followerCount: (json['follower_count'] as num?)?.toInt() ?? 0,
      streamTitle: json['stream_title'] as String?,
      streamCategory: json['stream_category'] as String?,
      displayScore: (json['display_score'] as num?)?.toInt() ?? 0,
      heatScore: (json['heat_score'] as num?)?.toDouble() ?? 0.0,
      platformUsername: conn?['platform_username'] as String?,
    );
  }
}
