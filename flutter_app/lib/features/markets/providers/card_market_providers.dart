import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth/providers/auth_provider.dart';

/// Card-centric prediction markets (Collections spec N5) — token-settled events
/// resolved from internal tables: card ascension, collection sell-out, and
/// Champion Spotlight. Distinct from the display-score markets on /markets.
/// All creation goes through the server RPCs (mig 174); bets are the same
/// token-bet insert the display-score markets use (DB triggers pool + debit).

class CardMarket {
  const CardMarket({
    required this.id,
    required this.title,
    required this.resolutionType,
    required this.yesPool,
    required this.noPool,
    required this.endAt,
  });

  final String id;
  final String title;
  final String resolutionType;
  final int yesPool;
  final int noPool;
  final DateTime? endAt;

  String get typeLabel => switch (resolutionType) {
        'card_ascension_time' => 'Ascension',
        'collection_sellout_date' => 'Sell-out',
        'spotlight_champion' => 'Spotlight',
        _ => 'Market',
      };

  factory CardMarket.fromRow(Map<String, dynamic> r) => CardMarket(
        id: r['id'] as String,
        title: (r['title'] ?? '').toString(),
        resolutionType: (r['resolution_type'] ?? '').toString(),
        yesPool: (r['yes_pool'] as num?)?.toInt() ?? 0,
        noPool: (r['no_pool'] as num?)?.toInt() ?? 0,
        endAt: DateTime.tryParse((r['end_at'] ?? '').toString()),
      );
}

/// Open card-centric markets (the three N5 resolution types), newest first.
final openCardMarketsProvider =
    FutureProvider.autoDispose<List<CardMarket>>((ref) async {
  final rows = await Supabase.instance.client
      .from('markets')
      .select('id, title, resolution_type, yes_pool, no_pool, end_at')
      .eq('status', 'open')
      .inFilter('resolution_type', const [
        'card_ascension_time',
        'collection_sellout_date',
        'spotlight_champion',
      ])
      .order('created_at', ascending: false);
  return (rows as List)
      .map((e) => CardMarket.fromRow(e as Map<String, dynamic>))
      .toList();
});

class CardMarketService {
  static SupabaseClient get _client => Supabase.instance.client;

  static Future<String> createAscensionMarket(
      {required String chitId,
      required String targetTier,
      required DateTime endAt}) async {
    final res = await _client.rpc('create_card_ascension_market', params: {
      'p_chit_id': chitId,
      'p_target_tier': targetTier,
      'p_end_at': endAt.toIso8601String(),
    });
    return res as String;
  }

  static Future<String> createSelloutMarket(
      {required String collectionId, required DateTime endAt}) async {
    final res = await _client.rpc('create_collection_sellout_market', params: {
      'p_collection_id': collectionId,
      'p_end_at': endAt.toIso8601String(),
    });
    return res as String;
  }

  /// Opens a "will @candidate be a Champion Spotlight in week W?" market.
  /// [weekStart] must be a Monday (the spotlight assignment key, mig 041).
  static Future<String> createSpotlightMarket(
      {required String candidateUserId,
      required DateTime weekStart,
      required DateTime endAt}) async {
    final res = await _client.rpc('create_spotlight_champion_market', params: {
      'p_candidate': candidateUserId,
      'p_week_start': _dateOnly(weekStart),
      'p_end_at': endAt.toIso8601String(),
    });
    return res as String;
  }

  static String _dateOnly(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Places a token bet (same path as display-score markets — the DB triggers
  /// update the pool + debit tokens). The mig-174 guard blocks a card's minter
  /// from betting its own ascension market.
  static Future<void> placeBet(
      {required String marketId,
      required String position, // 'yes' | 'no'
      required int amount}) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw StateError('Not signed in');
    await _client.from('bets').insert({
      'market_id': marketId,
      'user_id': userId,
      'position': position,
      'amount': amount,
      'status': 'active',
    });
  }

  static String errorMessage(Object e) =>
      e is PostgrestException ? e.message : '$e';
}

/// Convenience: the user's own active chits (for the ascension-market picker).
final myAscendableChitsProvider =
    FutureProvider.autoDispose<List<({String id, String name, String tier})>>(
        (ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return [];
  final client = Supabase.instance.client;
  final owned = await client
      .from('chit_ownership')
      .select('chit_id')
      .eq('user_id', user.id)
      .gt('quantity', 0);
  final ids =
      (owned as List).map((e) => (e as Map)['chit_id'] as String).toList();
  if (ids.isEmpty) return [];
  final rows = await client
      .from('moment_chits')
      .select('id, name, tier')
      .inFilter('id', ids)
      .eq('is_active', true);
  return (rows as List)
      .map((e) => (
            id: (e as Map)['id'] as String,
            name: (e['name'] ?? 'Card').toString(),
            tier: (e['tier'] ?? '').toString(),
          ))
      .toList();
});
