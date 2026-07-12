import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth/providers/auth_provider.dart';

// Cross-platform CCG matchmaking (migration 159, NORA_PLATFORMS_CROSSPLAY_SPEC.md).
// Web and the NORA Arena mobile app share ONE queue: ccg_queue_join/poll/leave are
// the whole client surface, pairing + deck legality live server-side. A waiting
// player hears "matched" via realtime on their own ccg_queue row (RLS-scoped),
// with ccg_queue_poll as the fallback heartbeat.

class MatchmakingService {
  static SupabaseClient get _client => Supabase.instance.client;

  /// Join the shared queue with a deck. Server returns one of:
  /// {status: matched, match_id} — an opponent was waiting; play now.
  /// {status: queued, queue_size} — waiting; poll/subscribe for the pair.
  /// {status: in_match, match_id} — already seated in a live match; resume it.
  /// {status: deck_illegal, errors[]} — the deck failed live validation.
  static Future<Map<String, dynamic>> join(String deckId) async {
    final res = await _client.rpc('ccg_queue_join',
        params: {'p_deck_id': deckId, 'p_platform': 'web'});
    return Map<String, dynamic>.from(res as Map);
  }

  /// Heartbeat + state: matched | queued (position/size/wait) | in_match | idle.
  static Future<Map<String, dynamic>> poll() async {
    final res = await _client.rpc('ccg_queue_poll');
    return Map<String, dynamic>.from(res as Map);
  }

  /// Back out of the queue. If an opponent paired first this returns
  /// {status: matched, match_id} — the match already exists, go play it.
  static Future<Map<String, dynamic>> leave() async {
    final res = await _client.rpc('ccg_queue_leave');
    return Map<String, dynamic>.from(res as Map);
  }

  /// Concede an active match (winner = the other seat; settlement triggers run).
  static Future<Map<String, dynamic>> forfeit(String matchId) async {
    final res =
        await _client.rpc('ccg_forfeit_match', params: {'p_match_id': matchId});
    return Map<String, dynamic>.from(res as Map);
  }

  /// Ordered whole-turn submission (v3 resolver contract, mig 129): the action
  /// list is resolved atomically and the turn advances. The server validates
  /// everything — this client only stages.
  static Future<Map<String, dynamic>> submitTurn(
      String matchId, List<Map<String, dynamic>> actions) async {
    final res = await _client.rpc('ccg_submit_turn', params: {
      'p_match_id': matchId,
      'p_actions': [...actions, {'type': 'end'}],
    });
    return Map<String, dynamic>.from(res as Map);
  }
}

/// The caller's own queue row, live (realtime; RLS returns only own row).
/// When matched_match_id becomes non-null, the pair completed.
final myQueueRowProvider =
    StreamProvider.autoDispose<Map<String, dynamic>?>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) return Stream.value(null);
  return Supabase.instance.client
      .from('ccg_queue')
      .stream(primaryKey: ['user_id'])
      .eq('user_id', user.id)
      .map((rows) => rows.isEmpty ? null : rows.first);
});

/// A deck of the signed-in user, with live legality.
class MyDeck {
  final String id;
  final String name;
  final bool isLegal;
  final int cardCount;

  const MyDeck({
    required this.id,
    required this.name,
    required this.isLegal,
    required this.cardCount,
  });
}

final myDecksProvider = FutureProvider.autoDispose<List<MyDeck>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return [];
  final client = Supabase.instance.client;
  final rows = await client
      .from('decks')
      .select('id, name, is_legal, deck_chits(quantity)')
      .eq('user_id', user.id)
      .eq('is_active', true)
      .order('updated_at', ascending: false);
  return (rows as List).map((r) {
    final m = r as Map<String, dynamic>;
    final chits = (m['deck_chits'] as List?) ?? const [];
    var count = 0;
    for (final c in chits) {
      count += ((c as Map)['quantity'] as num?)?.toInt() ?? 0;
    }
    return MyDeck(
      id: m['id'] as String,
      name: (m['name'] ?? 'Deck').toString(),
      isLegal: m['is_legal'] == true,
      cardCount: count,
    );
  }).toList();
});

/// Total playable copies the user owns (drives the quick-build affordance:
/// a legal deck needs exactly 20 copies, max 2 per chit).
final ownedPlayableCopiesProvider = FutureProvider.autoDispose<int>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return 0;
  final rows = await Supabase.instance.client
      .from('chit_ownership')
      .select('quantity, chit_id, moment_chits!inner(is_active)')
      .eq('user_id', user.id)
      .gt('quantity', 0)
      .eq('moment_chits.is_active', true);
  var total = 0;
  for (final r in rows as List) {
    final q = ((r as Map)['quantity'] as num?)?.toInt() ?? 0;
    total += q > 2 ? 2 : q; // deck cap: max 2 copies per chit
  }
  return total;
});

/// Build (or rebuild) a "Quick Deck" from the user's strongest owned chits:
/// highest tier first, up to 2 copies each, exactly 20 cards. Server-side
/// deck_set_chits revalidates everything. Returns the deck id, or throws with
/// a readable message when the collection can't field 20 copies.
Future<String> quickBuildDeck() async {
  final client = Supabase.instance.client;
  final user = client.auth.currentUser;
  if (user == null) throw Exception('Not signed in');

  const tierRank = {'S': 0, 'A': 1, 'B': 2, 'C': 3, 'D': 4, 'E': 5, 'F': 6};
  final rows = await client
      .from('chit_ownership')
      .select('quantity, chit_id, moment_chits!inner(id, tier, is_active)')
      .eq('user_id', user.id)
      .gt('quantity', 0)
      .eq('moment_chits.is_active', true);

  final owned = (rows as List).map((r) {
    final m = r as Map<String, dynamic>;
    final chit = m['moment_chits'] as Map<String, dynamic>;
    return (
      chitId: chit['id'] as String,
      tier: (chit['tier'] ?? 'F').toString(),
      copies: ((m['quantity'] as num?)?.toInt() ?? 0).clamp(0, 2),
    );
  }).toList()
    ..sort((a, b) =>
        (tierRank[a.tier] ?? 9).compareTo(tierRank[b.tier] ?? 9));

  final picks = <Map<String, dynamic>>[];
  var total = 0;
  for (final o in owned) {
    if (total >= 20) break;
    final take = (20 - total) < o.copies ? (20 - total) : o.copies;
    if (take <= 0) continue;
    picks.add({'chit_id': o.chitId, 'quantity': take});
    total += take;
  }
  if (total < 20) {
    throw Exception(
        'A deck needs 20 cards (max 2 copies each) — you have $total playable '
        'copies. Mint, open packs, or buy on the Chit Market first.');
  }

  // Reuse the existing Quick Deck row if present (unique user+name).
  final existing = await client
      .from('decks')
      .select('id')
      .eq('user_id', user.id)
      .eq('name', 'Quick Deck')
      .maybeSingle();
  final String deckId;
  if (existing != null) {
    deckId = existing['id'] as String;
  } else {
    final created = await client
        .from('decks')
        .insert({'user_id': user.id, 'name': 'Quick Deck'})
        .select('id')
        .single();
    deckId = created['id'] as String;
  }

  final result = await client.rpc('deck_set_chits',
      params: {'p_deck_id': deckId, 'p_chits': picks});
  final map = Map<String, dynamic>.from(result as Map);
  if (map['is_valid'] != true) {
    throw Exception('Deck validation failed: ${map['errors']}');
  }
  return deckId;
}

/// The signed-in user's live (non-test) match, if any — drives the
/// "You have a match in progress" resume banner on the Battle hub.
final myActiveCcgMatchProvider =
    FutureProvider.autoDispose<String?>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return null;
  final rows = await Supabase.instance.client
      .from('ccg_match_players')
      .select('match_id, ccg_matches!inner(id, status, is_test)')
      .eq('user_id', user.id)
      .eq('ccg_matches.status', 'active')
      .eq('ccg_matches.is_test', false)
      .limit(1);
  final list = rows as List;
  return list.isEmpty ? null : (list.first as Map)['match_id'] as String;
});

/// The caller's seat in a match (null while loading / not a participant).
final mySeatProvider =
    FutureProvider.autoDispose.family<int?, String>((ref, matchId) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return null;
  final row = await Supabase.instance.client
      .from('ccg_match_players')
      .select('seat')
      .eq('match_id', matchId)
      .eq('user_id', user.id)
      .maybeSingle();
  return row == null ? null : (row['seat'] as num).toInt();
});

/// The caller's hand, live. RLS only ever returns the caller's own hand rows
/// (opponent hands are invisible by policy), so filtering zone client-side on
/// the match stream is safe.
final myHandStreamProvider = StreamProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, matchId) {
  return Supabase.instance.client
      .from('ccg_match_cards')
      .stream(primaryKey: ['id'])
      .eq('match_id', matchId)
      .map((rows) => rows.where((r) => r['zone'] == 'hand').toList()
        ..sort((a, b) => ((a['deck_order'] as num?) ?? 0)
            .compareTo((b['deck_order'] as num?) ?? 0)));
});
