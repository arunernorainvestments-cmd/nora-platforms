import 'platform_connection.dart';
import 'platform_metric.dart';

class PublicProfileData {
  final String id;
  final String username;
  final String? bio;
  final String? category1;
  final String? category2;
  final bool isMarketMaker;
  final List<PlatformConnection> connections;
  final List<PlatformMetric> metrics;

  const PublicProfileData({
    required this.id,
    required this.username,
    this.bio,
    this.category1,
    this.category2,
    required this.isMarketMaker,
    required this.connections,
    required this.metrics,
  });
}
