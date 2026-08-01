import 'platform_connection.dart';
import 'platform_metric.dart';

class PublicProfileData {
  final String id;
  final String username;
  final String? bio;
  final String? category1;
  final String? subcategory;
  final bool isMarketMaker;

  /// Founding Market Makers cohort (Playset spec S4.2) — cosmetic badge only.
  final bool isFoundingMarketMaker;
  final List<PlatformConnection> connections;
  final List<PlatformMetric> metrics;

  const PublicProfileData({
    required this.id,
    required this.username,
    this.bio,
    this.category1,
    this.subcategory,
    required this.isMarketMaker,
    this.isFoundingMarketMaker = false,
    required this.connections,
    required this.metrics,
  });

  int get compositeDisplayScore =>
      metrics.fold(0, (sum, m) => sum + m.displayScore);
}
