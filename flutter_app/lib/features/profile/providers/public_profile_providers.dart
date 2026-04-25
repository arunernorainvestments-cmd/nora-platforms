import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/platform_connection.dart';
import '../models/platform_metric.dart';
import '../models/public_profile_data.dart';

final publicProfileProvider =
    FutureProvider.autoDispose.family<PublicProfileData?, String>(
        (ref, username) async {
  final client = Supabase.instance.client;

  // 1. Fetch profile row
  final profileData = await client
      .from('profiles')
      .select('id, username, bio, category_1, category_2, is_market_maker')
      .eq('username', username)
      .maybeSingle();

  if (profileData == null) return null;

  final profileId = profileData['id'] as String;

  // 2. Fetch platform connections via public view (no tokens exposed, is_active
  //    filtered at DB level, publicly readable for all users)
  List<PlatformConnection> connections = [];
  try {
    final connData = await client
        .from('public_platform_connections')
        .select('platform, platform_username, connected_at, is_active')
        .eq('user_id', profileId);
    connections = (connData as List)
        .map((e) => PlatformConnection.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (_) {}

  // 3. Fetch platform metrics (public can only see is_live rows per RLS;
  //    own-profile view sees all rows)
  List<PlatformMetric> metrics = [];
  try {
    final metricsData = await client
        .from('platform_metrics')
        .select(
          'platform, heat_score, display_score, is_live, '
          'follower_count, live_viewer_count, '
          'recent_post_views, recent_post_reposts',
        )
        .eq('user_id', profileId);
    metrics = (metricsData as List)
        .map((e) => PlatformMetric.fromJson(e as Map<String, dynamic>))
        .toList();
  } catch (_) {}

  return PublicProfileData(
    id: profileId,
    username: profileData['username'] as String? ?? username,
    bio: profileData['bio'] as String?,
    category1: profileData['category_1'] as String?,
    category2: profileData['category_2'] as String?,
    isMarketMaker: profileData['is_market_maker'] as bool? ?? false,
    connections: connections,
    metrics: metrics,
  );
});
