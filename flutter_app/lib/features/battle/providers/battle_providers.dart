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
