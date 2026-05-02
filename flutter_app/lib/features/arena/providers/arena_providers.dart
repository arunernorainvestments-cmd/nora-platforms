import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/arena_match.dart';
import '../models/arena_state_model.dart';
import '../models/arena_event.dart';
import '../models/ability_config.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Match detail (one-time fetch)
// ─────────────────────────────────────────────────────────────────────────────

final arenaMatchProvider =
    FutureProvider.autoDispose.family<ArenaMatch, String>((ref, matchId) async {
  final data = await Supabase.instance.client
      .from('arena_matches')
      .select(
        'id, round, state, player_1_id, player_2_id, '
        'player_1_archetype, player_2_archetype, '
        'subcategory_p1, subcategory_p2, '
        'scheduled_start, actual_start, actual_end, '
        'winner_id, final_score_p1, final_score_p2, created_at, '
        'player_1:profiles!player_1_id(username, category_1, subcategory), '
        'player_2:profiles!player_2_id(username, category_1, subcategory)',
      )
      .eq('id', matchId)
      .single();
  return ArenaMatch.fromJson(data);
});

// ─────────────────────────────────────────────────────────────────────────────
// Live arena state (Realtime — updates each tick)
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
// Live events (Realtime — last 10, newest first)
// ─────────────────────────────────────────────────────────────────────────────

final arenaEventsProvider =
    StreamProvider.family<List<ArenaEvent>, String>((ref, matchId) {
  return Supabase.instance.client
      .from('arena_events')
      .stream(primaryKey: ['id'])
      .eq('match_id', matchId)
      .order('created_at', ascending: false)
      .limit(10)
      .map((rows) => rows.map(ArenaEvent.fromJson).toList());
});

// ─────────────────────────────────────────────────────────────────────────────
// Ability config (all archetypes; cached for session lifetime)
// ─────────────────────────────────────────────────────────────────────────────

final abilityConfigProvider =
    FutureProvider<List<AbilityConfig>>((ref) async {
  final rows = await Supabase.instance.client
      .from('arena_abilities')
      .select()
      .order('archetype')
      .order('ability_type');
  return rows.map(AbilityConfig.fromJson).toList();
});

// Abilities for a specific archetype (filters from above)
final archetypeAbilitiesProvider =
    Provider.family<AsyncValue<List<AbilityConfig>>, String>((ref, archetype) {
  return ref.watch(abilityConfigProvider).whenData(
    (all) => all.where((a) => a.archetype == archetype).toList(),
  );
});

// ─────────────────────────────────────────────────────────────────────────────
// Per-match cooldowns for current user (Realtime stream)
// Returns map of ability_id → last triggered_at
// ─────────────────────────────────────────────────────────────────────────────

final abilityCooldownsProvider =
    StreamProvider.family<Map<String, DateTime>, String>((ref, matchId) {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) {
    return Stream.value({});
  }
  // Stream all uses for this match; filter by userId in map (stream builder
  // only supports a single .eq() filter).
  return Supabase.instance.client
      .from('arena_ability_uses')
      .stream(primaryKey: ['id'])
      .eq('match_id', matchId)
      .order('triggered_at', ascending: false)
      .map((rows) {
        final Map<String, DateTime> map = {};
        for (final row in rows) {
          if (row['user_id'] != userId) continue;
          final id = row['ability_id'] as String;
          final at = DateTime.parse(row['triggered_at'] as String);
          if (!map.containsKey(id)) map[id] = at;
        }
        return map;
      });
});

// ─────────────────────────────────────────────────────────────────────────────
// Matchmaking
// ─────────────────────────────────────────────────────────────────────────────

class MatchmakingNotifier extends StateNotifier<AsyncValue<String?>> {
  MatchmakingNotifier() : super(const AsyncData(null));

  Future<String?> findMatch() async {
    state = const AsyncLoading();
    try {
      final client = Supabase.instance.client;

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
