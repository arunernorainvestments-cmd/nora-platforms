import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth/providers/auth_provider.dart';
import '../models/platform_connection.dart';
import '../models/platform_metric.dart';

// ─────────────────────────────────────────────────────────────────────────────
// User's connected platforms
// ─────────────────────────────────────────────────────────────────────────────

final platformConnectionsProvider =
    FutureProvider.autoDispose<List<PlatformConnection>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return [];
  final res = await Supabase.instance.client
      .from('platform_connections')
      .select('platform, platform_username, connected_at, is_active')
      .eq('user_id', user.id);
  return (res as List)
      .map((e) => PlatformConnection.fromJson(e as Map<String, dynamic>))
      .toList();
});

// ─────────────────────────────────────────────────────────────────────────────
// Live metrics feed for "Who's Live" tab
// ─────────────────────────────────────────────────────────────────────────────

final liveMetricsFeedProvider =
    FutureProvider.autoDispose<List<PlatformMetric>>((ref) async {
  final res = await Supabase.instance.client
      .from('platform_metrics')
      .select('*, platform_connections(platform_username)')
      .eq('is_live', true)
      .order('heat_score', ascending: false)
      .limit(50);

  final metrics = (res as List)
      .map((e) => PlatformMetric.fromJson(e as Map<String, dynamic>))
      .toList();

  if (metrics.isEmpty) return metrics;

  // Apply visibility_multiplier passive effect: effective_score = heat_score * (1 + multiplier)
  final userIds = metrics.map((m) => m.userId).where((id) => id.isNotEmpty).toList();
  final passiveRes = await Supabase.instance.client
      .from('user_passive_effects')
      .select('user_id, visibility_multiplier')
      .inFilter('user_id', userIds);

  final passiveMap = <String, double>{};
  for (final row in passiveRes as List) {
    passiveMap[row['user_id'] as String] =
        (row['visibility_multiplier'] as num?)?.toDouble() ?? 0.0;
  }

  metrics.sort((a, b) {
    final aEff = a.heatScore * (1 + (passiveMap[a.userId] ?? 0));
    final bEff = b.heatScore * (1 + (passiveMap[b.userId] ?? 0));
    return bEff.compareTo(aEff);
  });

  return metrics;
});
