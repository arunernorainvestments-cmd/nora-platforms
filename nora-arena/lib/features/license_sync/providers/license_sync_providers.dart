import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/unlocked_character.dart';
import '../../../core/services/license_sync_service.dart';
import '../../../core/services/nora_api_service.dart';
import '../../../core/services/supabase_service.dart';

// Plain Riverpod only — NO codegen / @riverpod / build_runner (CLAUDE.md rule 1).

final noraApiServiceProvider = Provider((ref) => NoraApiService());

final licenseSyncServiceProvider = Provider(
  (ref) => LicenseSyncService(ref.watch(noraApiServiceProvider)),
);

/// The user's imported, playable characters. autoDispose so a pull-to-refresh /
/// invalidate re-runs the sync against the licensing API.
final unlockedCharactersProvider =
    FutureProvider.autoDispose<List<UnlockedCharacter>>((ref) async {
  final userId = SupabaseService.currentUserId;
  if (userId == null) return [];
  return ref.watch(licenseSyncServiceProvider).importLicensedCharacters(userId);
});
