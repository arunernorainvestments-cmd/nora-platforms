import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth/providers/auth_provider.dart';

/// Collection-minter (Market Maker) surfaces — Collections spec Phase N2/N4.
/// A Collection is a themed multi-copy series of a KYC'd, social-linked minter's
/// own posts, each a serialized "# of N" card. All writes go through the
/// server-authoritative `collection_*` RPCs (mig 171); this layer reads the
/// public/own collection rows and calls those RPCs. Money is integer USD cents
/// on the sim/live-switched rail — the client never sees floats or crosses the
/// currency wall.

/// Whether the signed-in user may mint collections (KYC + a linked social).
class CollectionMinterStatus {
  const CollectionMinterStatus({
    required this.kycVerified,
    required this.linkedSocial,
    required this.eligible,
  });
  final bool kycVerified;
  final bool linkedSocial;
  final bool eligible;

  factory CollectionMinterStatus.fromRow(Map<String, dynamic> r) =>
      CollectionMinterStatus(
        kycVerified: r['kyc_verified'] == true,
        linkedSocial: r['linked_social'] == true,
        eligible: r['eligible'] == true,
      );
}

final collectionMinterStatusProvider =
    FutureProvider.autoDispose<CollectionMinterStatus>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    return const CollectionMinterStatus(
        kycVerified: false, linkedSocial: false, eligible: false);
  }
  final res = await Supabase.instance.client
      .rpc('my_collection_minter_status');
  return CollectionMinterStatus.fromRow(Map<String, dynamic>.from(res as Map));
});

/// A member card of a collection, with the per-copy count the minter holds and
/// the definition's fixed supply.
class CollectionMember {
  const CollectionMember({
    required this.chitId,
    required this.name,
    required this.family,
    required this.chitType,
    required this.tier,
    required this.totalSupply,
    required this.cardArtUrl,
    required this.serial,
    required this.finalized,
  });

  final String chitId;
  final String name;
  final String family;
  final String chitType;
  final String tier;
  final int totalSupply;
  final String? cardArtUrl;
  final String? serial;
  final bool finalized;

  factory CollectionMember.fromRow(Map<String, dynamic> r) {
    final c = (r['moment_chits'] as Map?)?.cast<String, dynamic>() ?? const {};
    return CollectionMember(
      chitId: r['chit_id'] as String,
      name: (c['name'] ?? 'BattleChit').toString(),
      family: (c['archetype_family'] ?? '').toString(),
      chitType: (c['chit_type'] ?? 'creature').toString(),
      tier: (c['tier'] ?? '').toString(),
      totalSupply: (c['total_supply'] as num?)?.toInt() ?? 1,
      cardArtUrl: c['card_art_url'] as String?,
      serial: c['card_serial'] as String?,
      finalized: c['finalized_at'] != null && c['is_active'] == true,
    );
  }
}

/// A collection owned by the signed-in minter (any status) or a public listing.
class Collection {
  const Collection({
    required this.id,
    required this.title,
    required this.description,
    required this.coverArtUrl,
    required this.status,
    required this.priceCents,
    required this.members,
  });

  final String id;
  final String title;
  final String? description;
  final String? coverArtUrl;
  final String status; // draft | minting | listed | sold_out | closed
  final int? priceCents;
  final List<CollectionMember> members;

  bool get isDraft => status == 'draft' || status == 'minting';
  bool get isListed => status == 'listed';

  factory Collection.fromRow(Map<String, dynamic> r) {
    final memberRows =
        (r['collection_chits'] as List?)?.cast<Map<String, dynamic>>() ??
            const [];
    final members = memberRows.map(CollectionMember.fromRow).toList()
      ..sort((a, b) => a.name.compareTo(b.name));
    return Collection(
      id: r['id'] as String,
      title: (r['title'] ?? '').toString(),
      description: r['description'] as String?,
      coverArtUrl: r['cover_art_url'] as String?,
      status: (r['status'] ?? 'draft').toString(),
      priceCents: (r['price_cents'] as num?)?.toInt(),
      members: members,
    );
  }
}

const _collectionSelect =
    'id, title, description, cover_art_url, status, price_cents, created_at, '
    'collection_chits(chit_id, display_order, '
    'moment_chits(name, archetype_family, chit_type, tier, total_supply, '
    'card_art_url, card_serial, finalized_at, is_active))';

/// The signed-in minter's own collections (any status).
final myCollectionsProvider =
    FutureProvider.autoDispose<List<Collection>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return [];
  final rows = await Supabase.instance.client
      .from('collections')
      .select(_collectionSelect)
      .eq('market_maker_user_id', user.id)
      .order('created_at', ascending: false);
  return (rows as List)
      .map((e) => Collection.fromRow(e as Map<String, dynamic>))
      .toList();
});

/// A single collection by id (public listings + own drafts, per RLS).
final collectionProvider = FutureProvider.autoDispose
    .family<Collection?, String>((ref, id) async {
  final rows = await Supabase.instance.client
      .from('collections')
      .select(_collectionSelect)
      .eq('id', id)
      .maybeSingle();
  return rows == null ? null : Collection.fromRow(rows);
});

/// Publicly listed collections (browse surface — N3 buy flow lands here).
final listedCollectionsProvider =
    FutureProvider.autoDispose<List<Collection>>((ref) async {
  final rows = await Supabase.instance.client
      .from('collections')
      .select(_collectionSelect)
      .inFilter('status', ['listed', 'sold_out'])
      .order('created_at', ascending: false);
  return (rows as List)
      .map((e) => Collection.fromRow(e as Map<String, dynamic>))
      .toList();
});

/// Thin wrappers over the server-authoritative collection RPCs (mig 171).
class CollectionService {
  static SupabaseClient get _client => Supabase.instance.client;

  static Future<String> create(String title,
      {String? description, String? coverArtUrl}) async {
    final res = await _client.rpc('collection_create', params: {
      'p_title': title,
      if (description != null) 'p_description': description,
      if (coverArtUrl != null) 'p_cover_art_url': coverArtUrl,
    });
    return res as String;
  }

  static Future<void> update(String collectionId,
      {String? title, String? description, String? coverArtUrl}) async {
    await _client.rpc('collection_update', params: {
      'p_collection': collectionId,
      if (title != null) 'p_title': title,
      if (description != null) 'p_description': description,
      if (coverArtUrl != null) 'p_cover_art_url': coverArtUrl,
    });
  }

  /// Publishes: fixes each member's supply (1–1000, forever), charges the
  /// config mint fee on the sim USD rail, generates copies, lists at price.
  /// [supplies] maps chit_id → total_supply.
  static Future<Map<String, dynamic>> publish(
    String collectionId, {
    required int priceCents,
    required Map<String, int> supplies,
  }) async {
    final res = await _client.rpc('collection_publish', params: {
      'p_collection': collectionId,
      'p_price_cents': priceCents,
      'p_supplies': [
        for (final e in supplies.entries)
          {'chit_id': e.key, 'total_supply': e.value},
      ],
    });
    return Map<String, dynamic>.from(res as Map);
  }

  static String errorMessage(Object e) =>
      e is PostgrestException ? e.message : '$e';
}
