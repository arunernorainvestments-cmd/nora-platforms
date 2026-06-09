import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/battle_models.dart';

// Live match state — drives timer sync and match-end detection.
final battleMatchStreamProvider =
    StreamProvider.family.autoDispose<BattleMatch?, String>((ref, matchId) {
  return Supabase.instance.client
      .from('battle_matches')
      .stream(primaryKey: ['id'])
      .eq('id', matchId)
      .map((rows) => rows.isEmpty ? null : BattleMatch.fromJson(rows.first));
});

// All participants for a match — HP/AP update here after each turn.
final battleParticipantsStreamProvider =
    StreamProvider.family.autoDispose<List<BattleParticipant>, String>((ref, matchId) {
  return Supabase.instance.client
      .from('battle_participants')
      .stream(primaryKey: ['id'])
      .eq('match_id', matchId)
      .map((rows) =>
          rows.map((r) => BattleParticipant.fromJson(r)).toList());
});

// Ability definitions for an archetype — loaded once at match start.
final battleAbilitiesProvider =
    FutureProvider.family.autoDispose<List<AbilityData>, String>((ref, archetype) async {
  final data = await Supabase.instance.client
      .from('battle_abilities')
      .select()
      .eq('archetype', archetype)
      .order('ability_slot');
  return (data as List)
      .map((r) => AbilityData.fromJson(r as Map<String, dynamic>))
      .toList();
});

// All characters the current user can field (self + owned card characters).
final eligibleCharactersProvider =
    FutureProvider.autoDispose<List<EligibleCharacter>>((ref) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return [];
  final data = await Supabase.instance.client
      .rpc('get_eligible_characters', params: {'p_user_id': userId});
  return (data as List)
      .map((r) => EligibleCharacter.fromJson(r as Map<String, dynamic>))
      .toList();
});

// Stat sheet for a creator (snap stats + effective stats post-poll).
final creatorStatSheetProvider =
    FutureProvider.family.autoDispose<StatSheet?, String>((ref, userId) async {
  final data = await Supabase.instance.client
      .from('creator_stat_sheets')
      .select()
      .eq('user_id', userId)
      .maybeSingle();
  return data == null ? null : StatSheet.fromJson(data);
});

// Current user's most-recent matchmaking queue row. When status flips to
// 'matched', matched_match_id points at the created battle.
final myBattleQueueProvider =
    StreamProvider.autoDispose<Map<String, dynamic>?>((ref) {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return Stream.value(null);
  return Supabase.instance.client
      .from('battle_matchmaking_queue')
      .stream(primaryKey: ['id'])
      .eq('user_id', userId)
      .map((rows) {
    if (rows.isEmpty) return null;
    final sorted = [...rows]..sort((a, b) =>
        (b['enqueued_at'] as String).compareTo(a['enqueued_at'] as String));
    return sorted.first;
  });
});

// Live queue depth per format (for "N waiting" hints on the matchmaking screen).
final battleQueueCountsProvider =
    FutureProvider.autoDispose<Map<String, int>>((ref) async {
  final rows = await Supabase.instance.client
      .from('battle_matchmaking_queue')
      .select('format')
      .eq('status', 'queued');
  final counts = <String, int>{'1v1': 0, '2v2': 0, '3v3': 0};
  for (final r in rows as List) {
    final f = r['format'] as String?;
    if (f != null && counts.containsKey(f)) counts[f] = counts[f]! + 1;
  }
  return counts;
});

// Battle matchmaking actions.
class BattleMatchmaking {
  const BattleMatchmaking();

  /// Joins the queue for [format] fielding [creatorId]. Returns the match id if
  /// a match formed immediately, otherwise null (still queued).
  Future<String?> enqueue({
    required String format,
    required String creatorId,
  }) async {
    final res = await Supabase.instance.client.rpc('battle_enqueue', params: {
      'p_format': format,
      'p_creator_id': creatorId,
    }) as Map<String, dynamic>;
    return res['match_id'] as String?;
  }

  Future<void> leave() async {
    await Supabase.instance.client.rpc('battle_leave_queue');
  }
}

final battleMatchmakingProvider =
    Provider<BattleMatchmaking>((ref) => const BattleMatchmaking());

// Current user's Battle Chit inventory (owned + quantity > 0), with definitions.
final chitInventoryProvider =
    FutureProvider.autoDispose<List<ChitInventoryItem>>((ref) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return [];
  final data = await Supabase.instance.client
      .from('user_battle_chits')
      .select(
          'chit_definition_id, quantity, battle_chit_definitions(name, description, rarity, effect_type, animation_key, requires_target)')
      .eq('user_id', userId)
      .gt('quantity', 0);
  return (data as List)
      .map((r) => ChitInventoryItem.fromJson(r as Map<String, dynamic>))
      .toList();
});

// Uses a chit in a live match. [targetParticipantId] is required for chits whose
// `requiresTarget` is true (disruption / wild_card); null otherwise.
final useChitProvider = Provider<UseChit>((ref) => const UseChit());

class UseChit {
  const UseChit();

  Future<void> call({
    required String matchId,
    required String participantId,
    required String chitDefinitionId,
    String? targetParticipantId,
  }) async {
    await Supabase.instance.client.rpc('battle_use_chit', params: {
      'p_match_id': matchId,
      'p_participant_id': participantId,
      'p_chit_def_id': chitDefinitionId,
      'p_target_participant_id': targetParticipantId,
    });
  }
}

// Battle-linked prediction market for a match (auto-created at match start).
final battleArenaMarketProvider =
    FutureProvider.family.autoDispose<Map<String, dynamic>?, String>(
        (ref, matchId) async {
  final data = await Supabase.instance.client
      .from('markets')
      .select('id, title, yes_pool, no_pool, status, resolution_type, battle_match_id')
      .eq('battle_match_id', matchId)
      .eq('resolution_type', 'battle_outcome')
      .maybeSingle();
  return data;
});
