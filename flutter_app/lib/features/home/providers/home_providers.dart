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

// Phase D: Arena Champions slot (populated from arena_spotlight_assignments)
class ChampionCreator {
  final String userId;
  final String? displayName;
  final String? username;
  final String? avatarUrl;
  final double displayScore;
  final double heatScore;
  final int slot;

  const ChampionCreator({
    required this.userId,
    this.displayName,
    this.username,
    this.avatarUrl,
    required this.displayScore,
    required this.heatScore,
    required this.slot,
  });

  factory ChampionCreator.fromJson(Map<String, dynamic> json) =>
      ChampionCreator(
        userId:       json['user_id'] as String,
        displayName:  json['display_name'] as String?,
        username:     json['username'] as String?,
        avatarUrl:    json['avatar_url'] as String?,
        displayScore: (json['display_score'] as num?)?.toDouble() ?? 0,
        heatScore:    (json['heat_score'] as num?)?.toDouble() ?? 0,
        slot:         (json['slot'] as num?)?.toInt() ?? 0,
      );

  String get displayLabel => displayName ?? username ?? 'Anonymous';
  String get initials => displayLabel.isNotEmpty ? displayLabel[0].toUpperCase() : '?';
}

// Phase D: Top Mover (trailing 7-day display_score growth)
class TopMoverCreator {
  final String userId;
  final String? displayName;
  final String? username;
  final String? avatarUrl;
  final double displayScore;
  final double weeklyGrowthPct;

  const TopMoverCreator({
    required this.userId,
    this.displayName,
    this.username,
    this.avatarUrl,
    required this.displayScore,
    required this.weeklyGrowthPct,
  });

  factory TopMoverCreator.fromJson(Map<String, dynamic> json) =>
      TopMoverCreator(
        userId:          json['user_id'] as String,
        displayName:     json['display_name'] as String?,
        username:        json['username'] as String?,
        avatarUrl:       json['avatar_url'] as String?,
        displayScore:    (json['display_score'] as num?)?.toDouble() ?? 0,
        weeklyGrowthPct: (json['weekly_growth_pct'] as num?)?.toDouble() ?? 0,
      );

  String get displayLabel => displayName ?? username ?? 'Anonymous';
  String get initials => displayLabel.isNotEmpty ? displayLabel[0].toUpperCase() : '?';
}

class DualSpotlightData {
  final List<ChampionCreator> champions;
  final List<TopMoverCreator> topMovers;

  const DualSpotlightData({required this.champions, required this.topMovers});

  static const empty = DualSpotlightData(champions: [], topMovers: []);
}

// Legacy model kept for compatibility with discover/markets/profile providers
// that still join spotlight_scores. home_screen.dart uses dualSpotlightProvider.
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
    final profile = json['profiles'] as Map<String, dynamic>?;
    return SpotlightCreator(
      userId:      json['user_id'] as String,
      displayName: profile?['display_name'] as String?,
      username:    profile?['username'] as String?,
      avatarUrl:   profile?['avatar_url'] as String?,
      score:       (json['score'] as num?)?.toDouble() ?? 0,
      tier:        json['tier'] as String? ?? 'listed',
    );
  }

  String get displayLabel => displayName ?? username ?? 'Anonymous';
  String get initials => displayLabel.isNotEmpty ? displayLabel[0].toUpperCase() : '?';
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
    final platforms = [
      json['platform_youtube'],
      json['platform_tiktok'],
      json['platform_x'],
      json['platform_twitch'],
      json['platform_kick'],
      json['platform_instagram'],
    ].where((v) => v != null).length;

    return HomeFamousCreator(
      id:              json['id'] as String,
      name:            json['name'] as String,
      totalFollowers:  (json['total_followers'] as num?)?.toInt() ?? 0,
      platformCount:   platforms,
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

// Phase D: Dual spotlight — calls compute-spotlight edge function.
// Returns both Arena Champions (locked weekly) and Top Movers (dynamic).
final dualSpotlightProvider =
    FutureProvider.autoDispose<DualSpotlightData>((ref) async {
  try {
    final response = await Supabase.instance.client.functions
        .invoke('compute-spotlight', method: HttpMethod.get);

    if (response.data == null) return DualSpotlightData.empty;
    final data = response.data as Map<String, dynamic>;

    final championsList = (data['champions'] as List?)
        ?.map((e) => ChampionCreator.fromJson(e as Map<String, dynamic>))
        .toList() ?? [];

    final topMoversList = (data['top_movers'] as List?)
        ?.map((e) => TopMoverCreator.fromJson(e as Map<String, dynamic>))
        .toList() ?? [];

    return DualSpotlightData(
      champions: championsList,
      topMovers: topMoversList,
    );
  } catch (_) {
    return DualSpotlightData.empty;
  }
});

// Legacy: reads from spotlight_scores (no longer updated by compute-spotlight).
// Kept to avoid breaking other provider chains; returns empty in practice.
final spotlightCreatorsProvider =
    FutureProvider.autoDispose<List<SpotlightCreator>>((ref) async {
  final data = await Supabase.instance.client
      .from('spotlight_scores')
      .select('user_id, score, tier, profiles(display_name, username, avatar_url)')
      .eq('tier', 'on_fire')
      .order('score', ascending: false)
      .limit(15);

  return (data as List)
      .map((e) => SpotlightCreator.fromJson(e as Map<String, dynamic>))
      .toList();
});

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

  all.shuffle();
  return all.take(5).toList();
});
