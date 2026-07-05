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

  /// Owned but not yet finalized into the deck (Hard Rule 39 preview gate).
  bool get isPending => !isActive;

  factory CollectionChit.fromRow(Map<String, dynamic> r) => CollectionChit(
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
      );
}

/// The user's owned chits. Two-step (ownership ids → chits) because the public
/// `moment_chits_select_active` RLS policy would otherwise expose every active
/// chit; scoping to `chit_ownership` returns only what this user owns (active or
/// still pending preview).
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
  if (ids.isEmpty) return [];

  final rows = await client
      .from('moment_chits')
      .select(
          'id, name, chit_type, archetype_family, tier, aura_cost, atk, hp, '
          'keywords, card_art_url, mp4_cutscene_url, is_active, previewed_at, '
          'original_minter_handle, source_platform, created_at, '
          'rules_text, flavor_text, card_serial')
      .inFilter('id', ids)
      .order('created_at', ascending: false);

  return (rows as List)
      .map((e) => CollectionChit.fromRow(e as Map<String, dynamic>))
      .toList();
});
