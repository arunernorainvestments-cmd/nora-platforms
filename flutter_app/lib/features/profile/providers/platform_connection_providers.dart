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
  return (res as List)
      .map((e) => PlatformMetric.fromJson(e as Map<String, dynamic>))
      .toList();
});
