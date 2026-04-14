import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ─────────────────────────────────────────────────────────────────────────────
// MODELS
// ─────────────────────────────────────────────────────────────────────────────

class HomeTokenBalance {
  final int availableTokens;

  const HomeTokenBalance({required this.availableTokens});

  static const empty = HomeTokenBalance(availableTokens: 0);

  factory HomeTokenBalance.fromJson(Map<String, dynamic> json) =>
      HomeTokenBalance(
        availableTokens: (json['available_tokens'] as num?)?.toInt() ?? 0,
      );
}

class SpotlightCreator {
  final String userId;
  final String? displayName;
  final String? username;
  final String? avatarUrl;
  final double score;
  final String tier;

  const SpotlightCreator({
    required this.userId,
    this.displayName,
    this.username,
    this.avatarUrl,
    required this.score,
    required this.tier,
  });

  factory SpotlightCreator.fromJson(Map<String, dynamic> json) {
    // spotlight_scores row with embedded profiles via FK
    final profile = json['profiles'] as Map<String, dynamic>?;
    return SpotlightCreator(
      userId: json['user_id'] as String,
      displayName: profile?['display_name'] as String?,
      username: profile?['username'] as String?,
      avatarUrl: profile?['avatar_url'] as String?,
      score: (json['score'] as num?)?.toDouble() ?? 0,
      tier: json['tier'] as String? ?? 'listed',
    );
  }

  String get displayLabel => displayName ?? username ?? 'Anonymous';

  String get initials =>
      displayLabel.isNotEmpty ? displayLabel[0].toUpperCase() : '?';
}

class HomeFamousCreator {
  final String id;
  final String name;
  final int totalFollowers;
  final int platformCount;

  const HomeFamousCreator({
    required this.id,
    required this.name,
    required this.totalFollowers,
    required this.platformCount,
  });

  factory HomeFamousCreator.fromJson(Map<String, dynamic> json) {
    // Count non-null platform columns
    final platforms = [
      json['platform_youtube'],
      json['platform_tiktok'],
      json['platform_x'],
      json['platform_twitch'],
      json['platform_kick'],
      json['platform_instagram'],
    ].where((v) => v != null).length;

    return HomeFamousCreator(
      id: json['id'] as String,
      name: json['name'] as String,
      totalFollowers: (json['total_followers'] as num?)?.toInt() ?? 0,
      platformCount: platforms,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PROVIDERS
// ─────────────────────────────────────────────────────────────────────────────

final homeTokenBalanceProvider =
    FutureProvider.autoDispose<HomeTokenBalance>((ref) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return HomeTokenBalance.empty;

  final data = await Supabase.instance.client
      .from('token_balances')
      .select('available_tokens')
      .eq('user_id', userId)
      .maybeSingle();

  if (data == null) return HomeTokenBalance.empty;
  return HomeTokenBalance.fromJson(data);
});

/// Top 3 on-fire creators for the Spotlight section.
/// Ordering: pinned entries (active spotlight_entry boost) first, then by
/// effective_score = score * (1 + visibility_multiplier) descending.
final spotlightCreatorsProvider =
    FutureProvider.autoDispose<List<SpotlightCreator>>((ref) async {
  // Fetch a larger pool so Dart-side re-sort can surface pinned entries correctly.
  final data = await Supabase.instance.client
      .from('spotlight_scores')
      .select('user_id, score, tier, profiles(display_name, username, avatar_url)')
      .eq('tier', 'on_fire')
      .order('score', ascending: false)
      .limit(15);

  final creators = (data as List)
      .map((e) => SpotlightCreator.fromJson(e as Map<String, dynamic>))
      .toList();

  if (creators.isEmpty) return creators;

  final userIds = creators.map((c) => c.userId).toList();
  final now = DateTime.now().toUtc().toIso8601String();

  // Fetch passive effects and active spotlight pins in parallel.
  final results = await Future.wait([
    Supabase.instance.client
        .from('user_passive_effects')
        .select('user_id, visibility_multiplier')
        .inFilter('user_id', userIds),
    Supabase.instance.client
        .from('active_boosts')
        .select('target_user_id')
        .eq('boost_type', 'spotlight_entry')
        .eq('is_cancelled', false)
        .gt('expires_at', now)
        .inFilter('target_user_id', userIds),
  ]);

  final passiveMap = <String, double>{};
  for (final row in results[0] as List) {
    passiveMap[row['user_id'] as String] =
        (row['visibility_multiplier'] as num?)?.toDouble() ?? 0.0;
  }

  final pinnedIds = (results[1] as List)
      .map((row) => row['target_user_id'] as String)
      .toSet();

  creators.sort((a, b) {
    // Pinned entries sort above organic regardless of score.
    final aPinned = pinnedIds.contains(a.userId) ? 1 : 0;
    final bPinned = pinnedIds.contains(b.userId) ? 1 : 0;
    if (aPinned != bPinned) return bPinned.compareTo(aPinned);
    // Within same group, sort by effective_score descending.
    final aEff = a.score * (1 + (passiveMap[a.userId] ?? 0));
    final bEff = b.score * (1 + (passiveMap[b.userId] ?? 0));
    return bEff.compareTo(aEff);
  });

  return creators.take(3).toList();
});

/// 5 random famous creators for the carousel.
/// Supabase doesn't support ORDER BY RANDOM() via the client, so we fetch
/// a small pool and shuffle in Dart.
final homeFamousCreatorsProvider =
    FutureProvider.autoDispose<List<HomeFamousCreator>>((ref) async {
  final data = await Supabase.instance.client
      .from('famous_creators')
      .select(
        'id, name, total_followers, platform_youtube, platform_tiktok, '
        'platform_x, platform_twitch, platform_kick, platform_instagram',
      )
      .order('total_followers', ascending: false)
      .limit(20);

  final all = (data as List)
      .map((e) => HomeFamousCreator.fromJson(e as Map<String, dynamic>))
      .toList();

  // Shuffle and take 5 for carousel variety on each visit
  all.shuffle();
  return all.take(5).toList();
});
