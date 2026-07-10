import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth/providers/auth_provider.dart';

/// A minted moment chit the signed-in user owns.
class CollectionChit {
  const CollectionChit({
    required this.id,
    required this.name,
    required this.chitType,
    required this.family,
    required this.tier,
    required this.auraCost,
    required this.atk,
    required this.hp,
    required this.cardArtUrl,
    required this.cutsceneUrl,
    required this.isActive,
    required this.previewed,
    required this.minterHandle,
    required this.sourcePlatform,
    required this.keywords,
    required this.rulesText,
    required this.flavor,
    required this.serial,
    this.listingId,
  });

  final String id;
  final String name;
  final String chitType;
  final String family;
  final String tier;
  final int auraCost;
  final int atk;
  final int hp;
  final String? cardArtUrl;
  final String? cutsceneUrl;
  final bool isActive;
  final bool previewed;
  final String? minterHandle;
  final String? sourcePlatform;
  final List<String> keywords;
  final String? rulesText;
  final String? flavor;
  final String? serial;

  /// Active marketplace listing holding this chit in escrow (mig 154), if any.
  final String? listingId;

  /// Owned but not yet finalized into the deck (Hard Rule 39 preview gate).
  bool get isPending => !isActive;

  /// Escrowed in an active fixed-price listing — held, not free (Hard Rule 40).
  bool get isListed => listingId != null;

  /// Eligible for the marketplace Sell action: finalized, live, not already
  /// listed. (The server re-checks everything; this only drives the UI.)
  bool get isSellable => isActive && !isListed;

  factory CollectionChit.fromRow(Map<String, dynamic> r,
          {String? listingId}) =>
      CollectionChit(
        id: r['id'] as String,
        name: (r['name'] ?? 'BattleChit').toString(),
        chitType: (r['chit_type'] ?? 'creature').toString(),
        family: (r['archetype_family'] ?? '').toString(),
        tier: (r['tier'] ?? '').toString(),
        auraCost: (r['aura_cost'] as num?)?.toInt() ?? 0,
        atk: (r['atk'] as num?)?.toInt() ?? 0,
        hp: (r['hp'] as num?)?.toInt() ?? 0,
        cardArtUrl: r['card_art_url'] as String?,
        cutsceneUrl: r['mp4_cutscene_url'] as String?,
        isActive: r['is_active'] == true,
        previewed: r['previewed_at'] != null,
        minterHandle: r['original_minter_handle'] as String?,
        sourcePlatform: r['source_platform'] as String?,
        keywords: (r['keywords'] as List?)?.map((e) => e.toString()).toList() ?? const [],
        rulesText: r['rules_text'] as String?,
        flavor: r['flavor_text'] as String?,
        serial: r['card_serial'] as String?,
        listingId: listingId,
      );
}

/// The user's owned chits. Two-step (ownership ids → chits) because the public
/// `moment_chits_select_active` RLS policy would otherwise expose every active
/// chit; scoping to `chit_ownership` returns only what this user owns (active or
/// still pending preview).
///
/// Also includes chits the user has LISTED on the marketplace: a listed chit's
/// copy leaves `chit_ownership` (escrow, mig 154) but it is still theirs until
/// sold — hiding it here would read as "my card vanished." Those come back
/// flagged with their `listingId` so the UI can show Listed/Delist.
final myCollectionProvider =
    FutureProvider.autoDispose<List<CollectionChit>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return [];
  final client = Supabase.instance.client;

  final owned = await client
      .from('chit_ownership')
      .select('chit_id')
      .eq('user_id', user.id)
      .gt('quantity', 0);
  final ids = (owned as List)
      .map((e) => (e as Map)['chit_id'] as String)
      .toList();

  final listed = await client
      .from('marketplace_listings')
      .select('id, chit_id')
      .eq('seller_user_id', user.id)
      .eq('status', 'active');
  final listingByChit = <String, String>{
    for (final e in listed as List)
      (e as Map)['chit_id'] as String: e['id'] as String,
  };

  final allIds = {...ids, ...listingByChit.keys}.toList();
  if (allIds.isEmpty) return [];

  final rows = await client
      .from('moment_chits')
      .select(
          'id, name, chit_type, archetype_family, tier, aura_cost, atk, hp, '
          'keywords, card_art_url, mp4_cutscene_url, is_active, previewed_at, '
          'original_minter_handle, source_platform, created_at, '
          'rules_text, flavor_text, card_serial')
      .inFilter('id', allIds)
      .order('created_at', ascending: false);

  return (rows as List).map((e) {
    final m = e as Map<String, dynamic>;
    return CollectionChit.fromRow(m, listingId: listingByChit[m['id']]);
  }).toList();
});

/// Where the signed-in user stands with the weekly ascension refresh
/// (migs 136/157). Reads their own `chit_ascension_log` (RLS: select-own) for
/// the cooldown and `ascension_review_queue` for held big jumps.
class AscensionStatus {
  const AscensionStatus({this.lastRefreshedAt, this.pendingReviewCount = 0});

  final DateTime? lastRefreshedAt;

  /// Chits held in the manual review queue (≥3-rank jumps) awaiting approval.
  final int pendingReviewCount;

  DateTime? get nextRefreshAt =>
      lastRefreshedAt?.add(const Duration(days: 7));

  bool get canRefresh =>
      nextRefreshAt == null || nextRefreshAt!.isBefore(DateTime.now());
}

final ascensionStatusProvider =
    FutureProvider.autoDispose<AscensionStatus>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return const AscensionStatus();
  final client = Supabase.instance.client;

  final log = await client
      .from('chit_ascension_log')
      .select('refreshed_at')
      .eq('user_id', user.id)
      .order('refreshed_at', ascending: false)
      .limit(1)
      .maybeSingle();

  final pending = await client
      .from('ascension_review_queue')
      .select('id')
      .eq('user_id', user.id)
      .eq('status', 'pending');

  return AscensionStatus(
    lastRefreshedAt: log == null
        ? null
        : DateTime.tryParse((log['refreshed_at'] ?? '').toString()),
    pendingReviewCount: (pending as List).length,
  );
});
