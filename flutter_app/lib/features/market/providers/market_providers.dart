import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth/providers/auth_provider.dart';

/// The chit marketplace (migs 153–156) — fixed-price, token lane. All writes go
/// through the server-authoritative `marketplace_*` RPCs (Hard Rule 40); this
/// layer only reads the public listing/pricing models and calls those RPCs.
/// USD is intentionally absent here: the lane is founder-gated OFF (M2), and
/// the client never crosses the currency wall (Hard Rule 33).

/// One active fixed-price listing, joined with its chit's card-face fields.
class MarketListing {
  const MarketListing({
    required this.id,
    required this.chitId,
    required this.sellerUserId,
    required this.tier,
    required this.priceTokens,
    required this.feeBps,
    required this.name,
    required this.chitType,
    required this.family,
    required this.auraCost,
    required this.atk,
    required this.hp,
    required this.keywords,
    required this.cardArtUrl,
    required this.minterHandle,
    required this.sourcePlatform,
    required this.rulesText,
    required this.flavor,
    required this.serial,
  });

  final String id;
  final String chitId;
  final String sellerUserId;
  final String tier;
  final int priceTokens; // price_snapshot — frozen at list time
  final int feeBps; // fee_bps_snapshot — A/S burn, 0 for F–B
  final String name;
  final String chitType;
  final String family;
  final int auraCost;
  final int atk;
  final int hp;
  final List<String> keywords;
  final String? cardArtUrl;
  final String? minterHandle;
  final String? sourcePlatform;
  final String? rulesText;
  final String? flavor;
  final String? serial;

  /// The burn on this sale (integer floor, mirrors the RPC math).
  int get feeBurned => (priceTokens * feeBps) ~/ 10000;
  int get netToSeller => priceTokens - feeBurned;

  factory MarketListing.fromRow(Map<String, dynamic> r) {
    final c = (r['moment_chits'] as Map?)?.cast<String, dynamic>() ?? const {};
    return MarketListing(
      id: r['id'] as String,
      chitId: r['chit_id'] as String,
      sellerUserId: r['seller_user_id'] as String,
      tier: (r['tier_snapshot'] ?? '').toString(),
      priceTokens: (r['price_snapshot'] as num?)?.toInt() ?? 0,
      feeBps: (r['fee_bps_snapshot'] as num?)?.toInt() ?? 0,
      name: (c['name'] ?? 'BattleChit').toString(),
      chitType: (c['chit_type'] ?? 'creature').toString(),
      family: (c['archetype_family'] ?? '').toString(),
      auraCost: (c['aura_cost'] as num?)?.toInt() ?? 0,
      atk: (c['atk'] as num?)?.toInt() ?? 0,
      hp: (c['hp'] as num?)?.toInt() ?? 0,
      keywords:
          (c['keywords'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      cardArtUrl: c['card_art_url'] as String?,
      minterHandle: c['original_minter_handle'] as String?,
      sourcePlatform: c['source_platform'] as String?,
      rulesText: c['rules_text'] as String?,
      flavor: c['flavor_text'] as String?,
      serial: c['card_serial'] as String?,
    );
  }
}

const _listingSelect =
    'id, chit_id, seller_user_id, currency, tier_snapshot, price_snapshot, '
    'fee_bps_snapshot, created_at, '
    'moment_chits(name, chit_type, archetype_family, aura_cost, atk, hp, '
    'keywords, card_art_url, original_minter_handle, source_platform, '
    'rules_text, flavor_text, card_serial)';

/// Every active listing (public-read RLS), newest first.
final activeListingsProvider =
    FutureProvider.autoDispose<List<MarketListing>>((ref) async {
  final rows = await Supabase.instance.client
      .from('marketplace_listings')
      .select(_listingSelect)
      .eq('status', 'active')
      .order('created_at', ascending: false);
  return (rows as List)
      .map((e) => MarketListing.fromRow(e as Map<String, dynamic>))
      .toList();
});

/// The signed-in user's own active listings (at most 1 under the default
/// allowance, but modeled as a list so a raised allowance needs no rework).
final myListingsProvider =
    FutureProvider.autoDispose<List<MarketListing>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return [];
  final rows = await Supabase.instance.client
      .from('marketplace_listings')
      .select(_listingSelect)
      .eq('seller_user_id', user.id)
      .eq('status', 'active')
      .order('created_at', ascending: false);
  return (rows as List)
      .map((e) => MarketListing.fromRow(e as Map<String, dynamic>))
      .toList();
});

/// Fixed price + fee per tier (config table, public-read). Keyed by tier letter.
class TierPrice {
  const TierPrice({required this.tokens, required this.feeBps});
  final int tokens;
  final int feeBps;
  int get feeBurned => (tokens * feeBps) ~/ 10000;
  int get netToSeller => tokens - feeBurned;
}

final tierPricingProvider =
    FutureProvider.autoDispose<Map<String, TierPrice>>((ref) async {
  final rows = await Supabase.instance.client
      .from('marketplace_tier_pricing')
      .select('tier, token_price, fee_bps');
  return {
    for (final r in rows as List)
      (r as Map)['tier'] as String: TierPrice(
        tokens: (r['token_price'] as num).toInt(),
        feeBps: (r['fee_bps'] as num).toInt(),
      ),
  };
});

/// Thin wrappers over the server-authoritative RPCs (mig 155/156). Server
/// enforces everything (ownership, escrow, allowance, price); errors surface
/// as PostgrestException with the RAISE message.
class MarketService {
  static SupabaseClient get _client => Supabase.instance.client;

  /// Lists an owned chit at its fixed tier price. Returns the listing id.
  static Future<String> listChit(String chitId) async {
    final res = await _client
        .rpc('marketplace_list_chit', params: {'p_chit_id': chitId});
    return res as String;
  }

  /// Buys an active listing. Returns the sale receipt id (idempotent replay).
  static Future<String> buyListing(String listingId) async {
    final res = await _client
        .rpc('marketplace_buy_chit', params: {'p_listing_id': listingId});
    return res as String;
  }

  /// Returns the escrowed chit to the seller and closes the listing.
  static Future<void> delistListing(String listingId) async {
    await _client
        .rpc('marketplace_delist_chit', params: {'p_listing_id': listingId});
  }

  /// Human-readable message from an RPC failure.
  static String errorMessage(Object e) =>
      e is PostgrestException ? e.message : '$e';
}
