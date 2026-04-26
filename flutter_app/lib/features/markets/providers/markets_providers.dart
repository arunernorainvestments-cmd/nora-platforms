import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';

// ─────────────────────────────────────────────────────────────────────────────
// MODELS
// ─────────────────────────────────────────────────────────────────────────────

class MarketListing {
  final String id;
  final String creatorId;
  final String creatorUsername;
  final String? creatorTier;
  final String title;
  final String timeframe;
  final double yesPool;
  final double noPool;
  final DateTime endAt;
  final String? category1;
  final String? category2;

  const MarketListing({
    required this.id,
    required this.creatorId,
    required this.creatorUsername,
    this.creatorTier,
    required this.title,
    required this.timeframe,
    required this.yesPool,
    required this.noPool,
    required this.endAt,
    this.category1,
    this.category2,
  });

  double get totalPool => yesPool + noPool;

  factory MarketListing.fromJson(Map<String, dynamic> json) {
    final creator = json['creator'] as Map<String, dynamic>? ?? {};
    final scores = creator['spotlight_scores'] as List?;
    final tier = (scores != null && scores.isNotEmpty)
        ? scores.first['tier'] as String?
        : null;

    return MarketListing(
      id: json['id'] as String,
      creatorId: json['creator_id'] as String,
      creatorUsername: creator['username'] as String? ?? 'unknown',
      creatorTier: tier,
      title: json['title'] as String? ?? '',
      timeframe: json['timeframe'] as String,
      yesPool: (json['yes_pool'] as num?)?.toDouble() ?? 0,
      noPool: (json['no_pool'] as num?)?.toDouble() ?? 0,
      endAt: DateTime.parse(json['end_at'] as String),
      category1: json['category_1'] as String?,
      category2: json['category_2'] as String?,
    );
  }
}

class MyBet {
  final String id;
  final String marketId;
  final String creatorUsername;
  final String marketTitle;
  final String timeframe;
  final String position; // 'yes' | 'no'
  final double amount;
  final double? potentialPayout;
  final String status; // 'active' | 'won' | 'lost' | 'refunded'
  final DateTime placedAt;
  final DateTime marketEndAt;
  final String marketStatus;
  final bool? resolvedOutcome; // true = YES won
  final String? identifier;

  const MyBet({
    required this.id,
    required this.marketId,
    required this.creatorUsername,
    required this.marketTitle,
    required this.timeframe,
    required this.position,
    required this.amount,
    this.potentialPayout,
    required this.status,
    required this.placedAt,
    required this.marketEndAt,
    required this.marketStatus,
    this.resolvedOutcome,
    this.identifier,
  });

  factory MyBet.fromJson(Map<String, dynamic> json) {
    final market = json['market'] as Map<String, dynamic>? ?? {};
    final creator = market['creator'] as Map<String, dynamic>? ?? {};

    return MyBet(
      id: json['id'] as String,
      marketId: json['market_id'] as String,
      creatorUsername: creator['username'] as String? ?? 'unknown',
      marketTitle: market['title'] as String? ?? '',
      timeframe: market['timeframe'] as String? ?? '',
      position: json['position'] as String,
      amount: (json['amount'] as num).toDouble(),
      potentialPayout: (json['potential_payout'] as num?)?.toDouble(),
      status: json['status'] as String? ?? 'active',
      placedAt: DateTime.parse(json['placed_at'] as String),
      marketEndAt: DateTime.parse(market['end_at'] as String),
      marketStatus: market['status'] as String? ?? 'open',
      resolvedOutcome: market['resolved_outcome'] as bool?,
      identifier: market['market_identifier'] as String?,
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PROVIDERS
// ─────────────────────────────────────────────────────────────────────────────

// ─────────────────────────────────────────────────────────────────────────────
// MARKET MAKER PROFILES (for the circular-card markets screen)
// ─────────────────────────────────────────────────────────────────────────────

class MarketMakerProfile {
  final String id;
  final String username;
  final String? category1;
  final String? subcategory;
  final bool isLive;

  const MarketMakerProfile({
    required this.id,
    required this.username,
    this.category1,
    this.subcategory,
    this.isLive = false,
  });

  MarketMakerProfile copyWith({bool? isLive}) => MarketMakerProfile(
        id: id,
        username: username,
        category1: category1,
        subcategory: subcategory,
        isLive: isLive ?? this.isLive,
      );

  factory MarketMakerProfile.fromJson(Map<String, dynamic> json) =>
      MarketMakerProfile(
        id: json['id'] as String,
        username: json['username'] as String? ?? '',
        category1: json['category_1'] as String?,
        subcategory: json['subcategory'] as String?,
      );
}

/// All Market Makers who accept new markets (is_market_maker=true, pending_opt_out=false),
/// annotated with live status from platform_metrics.
final marketMakersProvider =
    FutureProvider.autoDispose<List<MarketMakerProfile>>((ref) async {
  final client = Supabase.instance.client;

  final data = await client
      .from('profiles')
      .select('id, username, category_1, subcategory')
      .eq('is_market_maker', true)
      .eq('pending_opt_out', false)
      .eq('is_test_account', false);

  final makers = (data as List)
      .map((e) => MarketMakerProfile.fromJson(e as Map<String, dynamic>))
      .toList();

  if (makers.isEmpty) return makers;

  final liveRes = await client
      .from('platform_metrics')
      .select('user_id')
      .eq('is_live', true);

  final liveIds =
      (liveRes as List).map((e) => e['user_id'] as String).toSet();

  return makers
      .map((m) => m.copyWith(isLive: liveIds.contains(m.id)))
      .toList();
});

final openMarketsProvider =
    FutureProvider.autoDispose<List<MarketListing>>((ref) async {
  final data = await Supabase.instance.client
      .from('markets')
      .select(
          'id, creator_id, title, timeframe, yes_pool, no_pool, end_at, '
          'category_1, category_2, '
          'creator:profiles!creator_id(username, spotlight_scores(tier))')
      .eq('status', 'open')
      .gt('end_at', DateTime.now().toUtc().toIso8601String());

  final markets = (data as List)
      .map((e) => MarketListing.fromJson(e as Map<String, dynamic>))
      .toList();

  // Sort by total pool size descending
  markets.sort((a, b) => b.totalPool.compareTo(a.totalPool));
  return markets;
});

// ─────────────────────────────────────────────────────────────────────────────
// MARKET DETAIL
// ─────────────────────────────────────────────────────────────────────────────

class MarketDetail {
  final String id;
  final String creatorId;
  final String creatorUsername;
  final String title;
  final String timeframe;
  final String? durationLabel;
  final double yesPool;
  final double noPool;
  final DateTime endAt;
  final DateTime? createdAt;
  final int? openingResolutionScore;
  final double? heatScore;
  final bool isLive;
  final int liveViewerCount;
  final String? primaryPlatform;
  final String? primaryPlatformUsername;
  final String status;
  final DateTime? resolvedAt;
  final String? resolutionResult; // 'above' | 'below' | 'refund' | null
  final String? marketSeries;
  final String? marketEvent;
  final String? identifier;
  final String? category1;
  final String? category2;
  final int compositeDisplayScore;

  const MarketDetail({
    required this.id,
    required this.creatorId,
    required this.creatorUsername,
    required this.title,
    required this.timeframe,
    this.durationLabel,
    required this.yesPool,
    required this.noPool,
    required this.endAt,
    this.createdAt,
    this.openingResolutionScore,
    this.heatScore,
    required this.isLive,
    required this.liveViewerCount,
    this.primaryPlatform,
    this.primaryPlatformUsername,
    required this.status,
    this.resolvedAt,
    this.resolutionResult,
    this.marketSeries,
    this.marketEvent,
    this.identifier,
    this.category1,
    this.category2,
    this.compositeDisplayScore = 0,
  });

  double get totalPool => yesPool + noPool;

  String get durationDisplay =>
      durationLabel ?? timeframe;

  String get formattedTarget {
    if (openingResolutionScore == null) return '--';
    return NumberFormat('#,###').format(openingResolutionScore);
  }

  String get formattedComposite =>
      NumberFormat('#,###').format(compositeDisplayScore);

  static MarketDetail fromParts(
    Map<String, dynamic> market,
    Map<String, dynamic>? metrics,
    List<Map<String, dynamic>> allMetrics,
  ) {
    final creator = market['creator'] as Map<String, dynamic>? ?? {};
    final conn = metrics?['platform_connections'] as Map<String, dynamic>?;
    final composite = allMetrics.fold<int>(
      0,
      (sum, m) => sum + ((m['display_score'] as num?)?.toInt() ?? 0),
    );
    return MarketDetail(
      id: market['id'] as String,
      creatorId: market['creator_id'] as String,
      creatorUsername: creator['username'] as String? ?? 'unknown',
      title: market['title'] as String? ?? '',
      timeframe: market['timeframe'] as String? ?? '',
      durationLabel: market['duration_label'] as String?,
      yesPool: (market['yes_pool'] as num?)?.toDouble() ?? 0,
      noPool: (market['no_pool'] as num?)?.toDouble() ?? 0,
      endAt: DateTime.parse(market['end_at'] as String),
      createdAt: market['created_at'] != null
          ? DateTime.parse(market['created_at'] as String)
          : null,
      openingResolutionScore:
          (market['opening_resolution_score'] as num?)?.toInt(),
      heatScore: (metrics?['heat_score'] as num?)?.toDouble(),
      isLive: metrics?['is_live'] as bool? ?? false,
      liveViewerCount:
          (metrics?['live_viewer_count'] as num?)?.toInt() ?? 0,
      primaryPlatform: metrics?['platform'] as String?,
      primaryPlatformUsername: conn?['platform_username'] as String?,
      status: market['status'] as String? ?? 'open',
      resolvedAt: market['resolved_at'] != null
          ? DateTime.parse(market['resolved_at'] as String)
          : null,
      resolutionResult: market['resolution_result'] as String?,
      marketSeries: market['market_series'] as String?,
      marketEvent: market['market_event'] as String?,
      identifier: market['market_identifier'] as String?,
      category1: market['category_1'] as String?,
      category2: market['category_2'] as String?,
      compositeDisplayScore: composite,
    );
  }
}

final tokenBalanceProvider = FutureProvider.autoDispose<int>((ref) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return 0;
  final res = await Supabase.instance.client
      .from('token_balances')
      .select('available_tokens')
      .eq('user_id', userId)
      .maybeSingle();
  return (res?['available_tokens'] as num?)?.toInt() ?? 0;
});

final marketDetailProvider =
    FutureProvider.autoDispose.family<MarketDetail, String>((ref, marketId) async {
  final client = Supabase.instance.client;

  final marketData = await client
      .from('markets')
      .select(
        'id, creator_id, title, timeframe, duration_label, '
        'yes_pool, no_pool, end_at, created_at, opening_resolution_score, status, '
        'resolved_at, resolution_result, '
        'market_series, market_event, market_identifier, '
        'category_1, category_2, '
        'creator:profiles!creator_id(username)',
      )
      .eq('id', marketId)
      .single();

  final creatorId = marketData['creator_id'] as String;

  // Fetch primary metrics row (for live status, heat score, platform badge)
  final metricsData = await client
      .from('platform_metrics')
      .select(
        'heat_score, is_live, live_viewer_count, platform, '
        'platform_connections(platform_username)',
      )
      .eq('user_id', creatorId)
      .limit(1)
      .maybeSingle();

  // Fetch all platform_metrics rows to compute composite display_score
  final allMetricsData = await client
      .from('platform_metrics')
      .select('display_score')
      .eq('user_id', creatorId);

  return MarketDetail.fromParts(
    marketData,
    metricsData,
    (allMetricsData as List).cast<Map<String, dynamic>>(),
  );
});

// ─────────────────────────────────────────────────────────────────────────────

/// Set of creator_ids whose platform_metrics row has is_live = true.
/// Used client-side to power the "Live Now" filter on Open Markets.
final liveCreatorIdsProvider =
    FutureProvider.autoDispose<Set<String>>((ref) async {
  final res = await Supabase.instance.client
      .from('platform_metrics')
      .select('user_id')
      .eq('is_live', true);
  return (res as List).map((e) => e['user_id'] as String).toSet();
});

final myBetsProvider =
    FutureProvider.autoDispose<List<MyBet>>((ref) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return [];

  final data = await Supabase.instance.client
      .from('bets')
      .select(
          'id, market_id, position, amount, potential_payout, status, placed_at, '
          'market:markets!market_id('
          '  id, title, timeframe, end_at, yes_pool, no_pool, status, resolved_outcome, market_identifier, '
          '  creator:profiles!creator_id(username)'
          ')')
      .eq('user_id', userId)
      .order('placed_at', ascending: false);

  return (data as List)
      .map((e) => MyBet.fromJson(e as Map<String, dynamic>))
      .toList();
});
