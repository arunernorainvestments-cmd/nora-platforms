import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/arena_match.dart';
import '../models/arena_state_model.dart';
import '../models/arena_event.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Match detail (one-time fetch — FutureProvider)
// ─────────────────────────────────────────────────────────────────────────────

final arenaMatchProvider =
    FutureProvider.autoDispose.family<ArenaMatch, String>((ref, matchId) async {
  final data = await Supabase.instance.client
      .from('arena_matches')
      .select(
        'id, round, state, player_1_id, player_2_id, '
        'player_1_archetype, player_2_archetype, '
        'scheduled_start, actual_start, actual_end, '
        'winner_id, final_score_p1, final_score_p2, created_at, '
        'player_1:profiles!player_1_id(username, category_1), '
        'player_2:profiles!player_2_id(username, category_1)',
      )
      .eq('id', matchId)
      .single();
  return ArenaMatch.fromJson(data);
});

// ─────────────────────────────────────────────────────────────────────────────
// Live arena state (Realtime stream — updates every tick)
// ─────────────────────────────────────────────────────────────────────────────

final arenaStateProvider =
    StreamProvider.family<ArenaStateModel, String>((ref, matchId) {
  return Supabase.instance.client
      .from('arena_state')
      .stream(primaryKey: ['match_id'])
      .eq('match_id', matchId)
      .map((rows) => rows.isEmpty
          ? ArenaStateModel.empty(matchId)
          : ArenaStateModel.fromJson(rows.first));
});

// ─────────────────────────────────────────────────────────────────────────────
// Live events (Realtime stream — last 10, newest first)
// ─────────────────────────────────────────────────────────────────────────────

final arenaEventsProvider =
    StreamProvider.family<List<ArenaEvent>, String>((ref, matchId) {
  return Supabase.instance.client
      .from('arena_events')
      .stream(primaryKey: ['id'])
      .eq('match_id', matchId)
      .order('created_at', ascending: false)
      .limit(10)
      .map((rows) =>
          rows.map((r) => ArenaEvent.fromJson(r)).toList());
});

// ─────────────────────────────────────────────────────────────────────────────
// Matchmaking — creates/finds a match for the user to spectate
// ─────────────────────────────────────────────────────────────────────────────

class MatchmakingNotifier extends StateNotifier<AsyncValue<String?>> {
  MatchmakingNotifier() : super(const AsyncData(null));

  // Returns a match_id or null if no match could be created.
  // Flow:
  //   1. Call arena_matchmake(1) to create a fresh pair of test creators.
  //   2. If nothing was created (all creators busy), fall back to any existing
  //      live or pre_match match the user can spectate.
  Future<String?> findMatch() async {
    state = const AsyncLoading();
    try {
      final client = Supabase.instance.client;

      // Try to create a new match
      final created = await client.rpc(
        'arena_matchmake',
        params: {'p_limit': 1},
      );

      if (created is List && created.isNotEmpty) {
        final row = created.first as Map<String, dynamic>;
        final matchId = row['match_id'] as String?;
        if (matchId != null) {
          state = AsyncData(matchId);
          return matchId;
        }
      }

      // Fall back to an existing spectatable match
      final existing = await client
          .from('arena_matches')
          .select('id')
          .inFilter('state', ['pre_match', 'live'])
          .order('scheduled_start', ascending: true)
          .limit(1)
          .maybeSingle();

      final fallbackId = existing?['id'] as String?;
      state = AsyncData(fallbackId);
      return fallbackId;
    } catch (e, st) {
      state = AsyncError(e, st);
      return null;
    }
  }

  void reset() => state = const AsyncData(null);
}

final matchmakingProvider =
    StateNotifierProvider.autoDispose<MatchmakingNotifier, AsyncValue<String?>>(
  (ref) => MatchmakingNotifier(),
);
