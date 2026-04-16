import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/score_snapshot.dart';
import '../models/platform_metric.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Params type for the score history family provider
// ─────────────────────────────────────────────────────────────────────────────

class ScoreHistoryParams {
  final String userId;
  final DateTime since;

  const ScoreHistoryParams(this.userId, this.since);

  @override
  bool operator ==(Object other) =>
      other is ScoreHistoryParams &&
      userId == other.userId &&
      since == other.since;

  @override
  int get hashCode => Object.hash(userId, since);
}

// ─────────────────────────────────────────────────────────────────────────────
// Score history — queries score_history table for the selected time window
// ─────────────────────────────────────────────────────────────────────────────

final scoreHistoryProvider = FutureProvider.autoDispose
    .family<List<ScoreSnapshot>, ScoreHistoryParams>((ref, params) async {
  final res = await Supabase.instance.client
      .from('score_history')
      .select('composite_score, recorded_at')
      .eq('user_id', params.userId)
      .gte('recorded_at', params.since.toIso8601String())
      .order('recorded_at', ascending: true)
      .limit(500); // cap for performance — 5-min cron → 500 points ≈ ~42 hours
  return (res as List)
      .map((e) => ScoreSnapshot.fromJson(e as Map<String, dynamic>))
      .toList();
});

// ─────────────────────────────────────────────────────────────────────────────
// Per-platform metrics detail — for the breakdown section of the dashboard
// ─────────────────────────────────────────────────────────────────────────────

final platformMetricsDetailProvider = FutureProvider.autoDispose
    .family<List<PlatformMetric>, String>((ref, userId) async {
  final res = await Supabase.instance.client
      .from('platform_metrics')
      .select(
        'platform, follower_count, live_viewer_count, display_score, '
        'is_live, recent_post_views, recent_post_reposts, recent_post_likes, '
        'platform_connections(platform_username)',
      )
      .eq('user_id', userId);
  return (res as List)
      .map((e) => PlatformMetric.fromJson(e as Map<String, dynamic>))
      .toList();
});
