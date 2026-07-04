import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Spectator read path for the v3 card-battler (matches are PLAYED in the NORA
// Arena mobile app; web spectates — migration 147). All server-authoritative:
// we only ever render what the resolver emitted.

class CcgLiveMatch {
  final String id;
  final String status;
  final int turnNumber;
  final int activeSeat;
  final int currentVibe;
  final bool isMonetized;
  final DateTime createdAt;

  CcgLiveMatch.fromJson(Map<String, dynamic> j)
      : id = j['id'] as String,
        status = j['status'] as String? ?? 'active',
        turnNumber = (j['turn_number'] as num?)?.toInt() ?? 1,
        activeSeat = (j['active_seat'] as num?)?.toInt() ?? 1,
        currentVibe = (j['current_vibe'] as num?)?.toInt() ?? 0,
        isMonetized = j['is_monetized'] as bool? ?? false,
        createdAt = DateTime.tryParse(j['created_at'] as String? ?? '') ??
            DateTime.now();
}

class CcgSeat {
  final int seat;
  final String? userId;
  final int life;
  final int aura;
  final int maxAura;
  String username; // resolved separately (realtime rows carry no joins)

  CcgSeat.fromJson(Map<String, dynamic> j)
      : seat = (j['seat'] as num).toInt(),
        userId = j['user_id'] as String?,
        life = (j['life'] as num?)?.toInt() ?? 30,
        aura = (j['aura'] as num?)?.toInt() ?? 0,
        maxAura = (j['max_aura'] as num?)?.toInt() ?? 0,
        username = 'Player ${(j['seat'] as num).toInt()}';
}

class CcgEvent {
  final int turnNumber;
  final int sequenceInTurn;
  final String eventType;
  final int? actorSeat;
  final Map<String, dynamic> payload;
  final int? lifeP1After;
  final int? lifeP2After;

  CcgEvent.fromJson(Map<String, dynamic> j)
      : turnNumber = (j['turn_number'] as num?)?.toInt() ?? 0,
        sequenceInTurn = (j['sequence_in_turn'] as num?)?.toInt() ?? 0,
        eventType = j['event_type'] as String? ?? '',
        actorSeat = (j['actor_seat'] as num?)?.toInt(),
        payload = (j['payload'] as Map?)?.cast<String, dynamic>() ?? const {},
        lifeP1After = (j['life_p1_after'] as num?)?.toInt(),
        lifeP2After = (j['life_p2_after'] as num?)?.toInt();
}

// ── Live match list (Arena app matches; test/smoke matches filtered out — HR 15/22)
final liveCcgMatchesProvider =
    StreamProvider.autoDispose<List<CcgLiveMatch>>((ref) {
  return Supabase.instance.client
      .from('ccg_matches')
      .stream(primaryKey: ['id'])
      .eq('status', 'active')
      .order('created_at')
      .map((rows) => rows
          .where((r) => r['is_test'] != true)
          .map(CcgLiveMatch.fromJson)
          .toList());
});

// ── One match (live header state) ────────────────────────────────────────────
final ccgMatchStreamProvider = StreamProvider.autoDispose
    .family<CcgLiveMatch?, String>((ref, matchId) {
  return Supabase.instance.client
      .from('ccg_matches')
      .stream(primaryKey: ['id'])
      .eq('id', matchId)
      .map((rows) => rows.isEmpty ? null : CcgLiveMatch.fromJson(rows.first));
});

// ── Seats (life/aura, live) with usernames resolved once per rebuild ─────────
final ccgSeatsStreamProvider = StreamProvider.autoDispose
    .family<List<CcgSeat>, String>((ref, matchId) {
  return Supabase.instance.client
      .from('ccg_match_players')
      .stream(primaryKey: ['match_id', 'seat'])
      .eq('match_id', matchId)
      .asyncMap((rows) async {
    final seats = rows.map(CcgSeat.fromJson).toList()
      ..sort((a, b) => a.seat.compareTo(b.seat));
    final ids = seats.map((s) => s.userId).whereType<String>().toList();
    if (ids.isNotEmpty) {
      final profiles = await Supabase.instance.client
          .from('profiles')
          .select('id, username, display_name')
          .inFilter('id', ids);
      final names = <String, String>{
        for (final p in profiles as List)
          p['id'] as String: (p['display_name'] ?? p['username'] ?? 'Player')
              .toString(),
      };
      for (final s in seats) {
        if (s.userId != null && names.containsKey(s.userId)) {
          s.username = names[s.userId]!;
        }
      }
    }
    return seats;
  });
});

// ── Ordered event feed (live) ────────────────────────────────────────────────
final ccgEventsStreamProvider = StreamProvider.autoDispose
    .family<List<CcgEvent>, String>((ref, matchId) {
  return Supabase.instance.client
      .from('ccg_events')
      .stream(primaryKey: ['id'])
      .eq('match_id', matchId)
      .map((rows) {
    final events = rows.map(CcgEvent.fromJson).toList()
      ..sort((a, b) => a.turnNumber != b.turnNumber
          ? a.turnNumber.compareTo(b.turnNumber)
          : a.sequenceInTurn.compareTo(b.sequenceInTurn));
    return events;
  });
});

// ── Board cards (field/graveyard only — the spectator RLS line) ──────────────
final ccgBoardStreamProvider = StreamProvider.autoDispose
    .family<List<Map<String, dynamic>>, String>((ref, matchId) {
  return Supabase.instance.client
      .from('ccg_match_cards')
      .stream(primaryKey: ['id'])
      .eq('match_id', matchId)
      .map((rows) =>
          rows.where((r) => r['zone'] == 'field').toList()
            ..sort((a, b) => ((a['field_pos'] as num?) ?? 0)
                .compareTo((b['field_pos'] as num?) ?? 0)));
});
