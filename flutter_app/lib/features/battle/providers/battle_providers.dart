import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/battle_models.dart';

// Legacy 1v1 fighter providers were removed with the legacy web battle client
// (2026-07-12 crossplay pass). What remains here is the Likeness-card stat
// sheet read (cosmetic under v3), still shown on public profiles. The v3
// card-battler read path is providers/spectate_providers.dart; matchmaking +
// play live in providers/matchmaking_providers.dart.

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
