class PlatformConnection {
  final String platform;
  final String? platformUsername;
  final DateTime connectedAt;
  final bool isActive;

  const PlatformConnection({
    required this.platform,
    this.platformUsername,
    required this.connectedAt,
    required this.isActive,
  });

  factory PlatformConnection.fromJson(Map<String, dynamic> json) =>
      PlatformConnection(
        platform: json['platform'] as String,
        platformUsername: json['platform_username'] as String?,
        connectedAt: DateTime.parse(json['connected_at'] as String),
        isActive: json['is_active'] as bool? ?? true,
      );
}
