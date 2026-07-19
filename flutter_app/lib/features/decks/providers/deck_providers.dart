import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth/providers/auth_provider.dart';

// Deck-builder data layer (migration 118: decks / deck_chits / deck_set_chits).
// All mutations to deck contents go through the deck_set_chits SECURITY DEFINER
// RPC — the server is the only validator (size 20, max 2 copies, ownership,
// active chits). This file only stages and reads.

/// One chit the user can put in a deck: definition + how many copies they own.
class DeckableChit {
  const DeckableChit({
    required this.chitId,
    required this.name,
    required this.chitType,
    required this.family,
    required this.tier,
    required this.auraCost,
    required this.atk,
    required this.hp,
    required this.ownedCopies,
    this.cardArtUrl,
    this.rulesText,
  });

  final String chitId;
  final String name;
  final String chitType; // 'creature' | 'spell_moment'
  final String family;
  final String tier;
  final int auraCost;
  final int atk;
  final int hp;
  final String? cardArtUrl;
  final String? rulesText;

  /// Copies in the user's holdings (escrowed/listed copies are already gone
  /// from chit_ownership, so this is what a deck may legally use).
  final int ownedCopies;

  /// Copies a deck may hold: owned, capped by the 2-copy rule.
  int get deckableCopies => ownedCopies > 2 ? 2 : ownedCopies;
}

/// Everything the editor needs to open a deck: its row + saved contents +
/// the full deckable collection.
class DeckEditorData {
  const DeckEditorData({
    required this.deckId,
    required this.name,
    required this.isLegal,
    required this.savedCounts,
    required this.chits,
  });

  final String deckId;
  final String name;
  final bool isLegal;

  /// chit_id → quantity as currently saved on the server.
  final Map<String, int> savedCounts;

  /// Every chit the user could add, sorted strongest-first.
  final List<DeckableChit> chits;
}

const _tierRank = {'S': 0, 'A': 1, 'B': 2, 'C': 3, 'D': 4, 'E': 5, 'F': 6};

final deckEditorProvider = FutureProvider.autoDispose
    .family<DeckEditorData, String>((ref, deckId) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) throw Exception('Not signed in');
  final client = Supabase.instance.client;

  final deck = await client
      .from('decks')
      .select('id, name, is_legal')
      .eq('id', deckId)
      .single();

  final saved = await client
      .from('deck_chits')
      .select('chit_id, quantity')
      .eq('deck_id', deckId);
  final savedCounts = <String, int>{
    for (final r in saved as List)
      (r as Map)['chit_id'] as String: (r['quantity'] as num).toInt(),
  };

  final owned = await client
      .from('chit_ownership')
      .select('quantity, chit_id, moment_chits!inner(id, name, chit_type, '
          'archetype_family, tier, aura_cost, atk, hp, card_art_url, '
          'rules_text, is_active)')
      .eq('user_id', user.id)
      .gt('quantity', 0)
      .eq('moment_chits.is_active', true);

  final chits = (owned as List).map((r) {
    final m = r as Map<String, dynamic>;
    final c = m['moment_chits'] as Map<String, dynamic>;
    return DeckableChit(
      chitId: c['id'] as String,
      name: (c['name'] ?? 'BattleChit').toString(),
      chitType: (c['chit_type'] ?? 'creature').toString(),
      family: (c['archetype_family'] ?? '').toString(),
      tier: (c['tier'] ?? 'F').toString(),
      auraCost: (c['aura_cost'] as num?)?.toInt() ?? 0,
      atk: (c['atk'] as num?)?.toInt() ?? 0,
      hp: (c['hp'] as num?)?.toInt() ?? 0,
      cardArtUrl: c['card_art_url'] as String?,
      rulesText: c['rules_text'] as String?,
      ownedCopies: (m['quantity'] as num?)?.toInt() ?? 0,
    );
  }).toList()
    ..sort((a, b) {
      final t = (_tierRank[a.tier] ?? 9).compareTo(_tierRank[b.tier] ?? 9);
      if (t != 0) return t;
      return a.auraCost.compareTo(b.auraCost);
    });

  return DeckEditorData(
    deckId: deck['id'] as String,
    name: (deck['name'] ?? 'Deck').toString(),
    isLegal: deck['is_legal'] == true,
    savedCounts: savedCounts,
    chits: chits,
  );
});

/// Static deck operations. Contents always go through deck_set_chits so the
/// server validates atomically; name/create/delete are plain RLS-scoped writes
/// on the caller's own rows.
class DeckService {
  static SupabaseClient get _client => Supabase.instance.client;

  static Future<String> create(String name) async {
    final user = _client.auth.currentUser;
    if (user == null) throw Exception('Not signed in');
    final row = await _client
        .from('decks')
        .insert({'user_id': user.id, 'name': name})
        .select('id')
        .single();
    return row['id'] as String;
  }

  static Future<void> rename(String deckId, String name) async {
    await _client.from('decks').update({'name': name}).eq('id', deckId);
  }

  static Future<void> delete(String deckId) async {
    await _client.from('decks').delete().eq('id', deckId);
  }

  /// Replace the deck's contents. Returns the server validation result:
  /// {is_valid: bool, errors: [..], total: n}. Saving an incomplete deck is
  /// allowed — it just stays not-battle-legal until it validates.
  static Future<Map<String, dynamic>> save(
      String deckId, Map<String, int> counts) async {
    final picks = [
      for (final e in counts.entries)
        if (e.value > 0) {'chit_id': e.key, 'quantity': e.value},
    ];
    final res = await _client.rpc('deck_set_chits',
        params: {'p_deck_id': deckId, 'p_chits': picks});
    return Map<String, dynamic>.from(res as Map);
  }

  /// Server validation codes → human sentences.
  static String friendlyError(String code) {
    final size = RegExp(r'deck_size_must_be_(\d+)_got_(\d+)').firstMatch(code);
    if (size != null) {
      return 'A battle deck needs exactly ${size.group(1)} cards — this one '
          'has ${size.group(2)}.';
    }
    if (code.startsWith('max_')) {
      return 'A deck can hold at most 2 copies of any one BattleChit.';
    }
    return switch (code) {
      'contains_inactive_chit' =>
        'A card in this deck has been retired — remove it.',
      'does_not_own_all_chits' =>
        'You no longer hold enough copies of a card in this deck (it may be '
            'listed for sale or traded away).',
      'deck_not_found' => 'This deck no longer exists.',
      _ => code,
    };
  }
}
