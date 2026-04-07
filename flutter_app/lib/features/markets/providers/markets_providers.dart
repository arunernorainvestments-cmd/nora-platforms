import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PROVIDERS
// ─────────────────────────────────────────────────────────────────────────────

final openMarketsProvider =
    FutureProvider.autoDispose<List<MarketListing>>((ref) async {
  final data = await Supabase.instance.client
      .from('markets')
      .select(
          'id, creator_id, title, timeframe, yes_pool, no_pool, end_at, '
          'creator:profiles!creator_id(username, spotlight_scores(tier))')
      .eq('status', 'open');

  final markets = (data as List)
      .map((e) => MarketListing.fromJson(e as Map<String, dynamic>))
      .toList();

  // Sort by total pool size descending
  markets.sort((a, b) => b.totalPool.compareTo(a.totalPool));
  return markets;
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
          '  id, title, timeframe, end_at, yes_pool, no_pool, status, resolved_outcome, '
          '  creator:profiles!creator_id(username)'
          ')')
      .eq('user_id', userId)
      .order('placed_at', ascending: false);

  return (data as List)
      .map((e) => MyBet.fromJson(e as Map<String, dynamic>))
      .toList();
});
