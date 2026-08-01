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
    this.ownedSerials = const [],
    this.totalSupply = 1,
    this.collectionId,
    this.collectionTitle,
    this.isStarter = false,
    this.ownedQuantity = 0,
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

  /// Per-copy serial numbers this user holds (Collections spec N2 — chit_copies).
  /// A single self-mint has [1]; a collector may hold several serials of a chit.
  final List<int> ownedSerials;

  /// The definition's fixed supply (mig 170) — the N in "# of N".
  final int totalSupply;

  /// Collection membership (Collections spec N4), when this card belongs to one.
  final String? collectionId;
  final String? collectionTitle;

  /// Standard Playset card (mig 181/182): platform-authored, granted free at
  /// signup, playable everywhere — and never listable, tradeable or stakeable.
  final bool isStarter;

  /// Copies held. Starters are unserialized, so this is their only count.
  final int ownedQuantity;

  /// The lowest owned serial, for the "# of N" display line.
  int? get displaySerial =>
      ownedSerials.isEmpty ? null : (ownedSerials..sort()).first;

  /// "#3 of 100" for the lowest owned serial, or null for a lone 1-of-1.
  /// Starters have no serials at all — supply is unbounded by design — so they
  /// show their starter label instead (mig 181 REPO-CHECK S1.4).
  String? get copyOfLabel {
    if (isStarter) return 'Starter';
    final s = displaySerial;
    if (s == null) return null;
    return '#$s of $totalSupply';
  }

  /// Owned but not yet finalized into the deck (Hard Rule 39 preview gate).
  bool get isPending => !isActive;

  /// Escrowed in an active fixed-price listing — held, not free (Hard Rule 40).
  bool get isListed => listingId != null;

  /// Eligible for the marketplace Sell action: finalized, live, not already
  /// listed, not a starter (starters are never goods — mig 181 enforces it
  /// server-side; this only keeps the UI honest).
  bool get isSellable => isActive && !isListed && !isStarter;

  factory CollectionChit.fromRow(Map<String, dynamic> r,
          {String? listingId,
          List<int> ownedSerials = const [],
          int? totalSupply,
          String? collectionId,
          String? collectionTitle,
          int ownedQuantity = 0}) =>
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
        ownedSerials: ownedSerials,
        totalSupply: totalSupply ?? (r['total_supply'] as num?)?.toInt() ?? 1,
        collectionId: collectionId,
        collectionTitle: collectionTitle,
        isStarter: r['is_starter'] == true,
        ownedQuantity: ownedQuantity,
      );
}

/// Standard Playset self-heal (Playset spec S2). The grant normally lands in the
/// signup trigger; this is the client-side safety net for accounts whose signup
/// grant failed and for accounts created before the playset existed. The RPC is
/// idempotent behind a receipt row, so calling it is always safe — it returns
/// `granted: false` when there is nothing to do.
///
/// Deliberately NOT autoDispose: once per app session per user is enough.
final starterPlaysetProvider = FutureProvider<bool>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return false;
  try {
    final res = await Supabase.instance.client.rpc('claim_starter_playset');
    return (res is Map && res['granted'] == true);
  } catch (_) {
    // Never block the collection on the safety net.
    return false;
  }
});

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

  // Make sure the starter playset exists before we read holdings, so a first-time
  // account never sees an empty collection it should not have.
  await ref.watch(starterPlaysetProvider.future);

  final owned = await client
      .from('chit_ownership')
      .select('chit_id, quantity')
      .eq('user_id', user.id)
      .gt('quantity', 0);
  final ids = (owned as List)
      .map((e) => (e as Map)['chit_id'] as String)
      .toList();
  final qtyByChit = <String, int>{
    for (final e in owned)
      (e as Map)['chit_id'] as String: (e['quantity'] as num?)?.toInt() ?? 0,
  };

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

  // Per-copy serials this user holds (Collections spec N2 — chit_copies). Own +
  // listed_escrow copies are still "theirs" for display.
  final copies = await client
      .from('chit_copies')
      .select('chit_id, serial_number, total_supply')
      .eq('owner_user_id', user.id)
      .inFilter('state', ['owned', 'listed_escrow']);
  final serialsByChit = <String, List<int>>{};
  final supplyByChit = <String, int>{};
  for (final e in copies as List) {
    final m = e as Map;
    final cid = m['chit_id'] as String;
    (serialsByChit[cid] ??= []).add((m['serial_number'] as num).toInt());
    supplyByChit[cid] = (m['total_supply'] as num?)?.toInt() ?? 1;
  }

  // Collection membership → title (public for listed; own drafts readable).
  final members = await client
      .from('collection_chits')
      .select('chit_id, collections(id, title)')
      .inFilter('chit_id', allIds);
  final collByChit = <String, ({String id, String title})>{};
  for (final e in members as List) {
    final m = e as Map;
    final coll = (m['collections'] as Map?)?.cast<String, dynamic>();
    if (coll != null) {
      collByChit[m['chit_id'] as String] =
          (id: coll['id'] as String, title: (coll['title'] ?? '').toString());
    }
  }

  final rows = await client
      .from('moment_chits')
      .select(
          'id, name, chit_type, archetype_family, tier, aura_cost, atk, hp, '
          'keywords, card_art_url, mp4_cutscene_url, is_active, previewed_at, '
          'original_minter_handle, source_platform, created_at, '
          'rules_text, flavor_text, card_serial, total_supply, is_starter')
      .inFilter('id', allIds)
      .order('created_at', ascending: false);

  return (rows as List).map((e) {
    final m = e as Map<String, dynamic>;
    final cid = m['id'] as String;
    final coll = collByChit[cid];
    return CollectionChit.fromRow(
      m,
      listingId: listingByChit[cid],
      ownedSerials: serialsByChit[cid] ?? const [],
      totalSupply: supplyByChit[cid] ?? (m['total_supply'] as num?)?.toInt() ?? 1,
      collectionId: coll?.id,
      collectionTitle: coll?.title,
      ownedQuantity: qtyByChit[cid] ?? 0,
    );
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
