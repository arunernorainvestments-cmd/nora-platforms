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
