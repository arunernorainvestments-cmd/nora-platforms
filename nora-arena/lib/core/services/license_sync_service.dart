import 'package:flutter/foundation.dart';

import '../models/stat_sheet.dart';
import '../models/unlocked_character.dart';
import '../models/verified_license.dart';
import 'nora_api_service.dart';
import 'supabase_service.dart';

/// THE IMPORT FEATURE.
///
/// Turns licenses a user bought on noraplatforms.com into playable characters.
/// Authority split (ARCHITECTURE.md / CLAUDE.md rule 4):
///   • ownership      → N.O.R.A. licensing API (signed, authoritative)
///   • display assets → shared Supabase: lkn_public_registry (portrait, name,
///                      category — public read) + creator_stat_sheets (stats)
/// Never unlock from registry data alone.
class LicenseSyncService {
  final NoraApiService _api;
  LicenseSyncService(this._api);

  /// Full sync: verify → enrich → playable characters.
  Future<List<UnlockedCharacter>> importLicensedCharacters(
      String noraUserId) async {
    final licenses = await _api.listActiveGameLicenses(noraUserId);
    final out = <UnlockedCharacter>[];
    for (final lic in licenses) {
      final character = await _buildCharacter(lic);
      if (character != null) out.add(character);
    }
    return out;
  }

  /// Enrich one verified license into an [UnlockedCharacter].
  Future<UnlockedCharacter?> _buildCharacter(VerifiedLicense lic) async {
    try {
      final db = SupabaseService.client;

      // Display assets — public registry (RLS public read, no PII).
      final reg = await db
          .from('lkn_public_registry')
          .select('licensor_display_name, licensor_image_url, listing_category')
          .eq('license_id', lic.licenseId)
          .maybeSingle();
      if (reg == null) {
        debugPrint('[LicenseSync] no registry row for ${lic.licenseId}');
        return null;
      }

      // Battle numbers — the creator's shared stat sheet (may be null for a
      // licensor who isn't a battling creator; character still imports w/ defaults).
      StatSheet? stats;
      if (lic.licensorNoraId != null) {
        final s = await db
            .from('creator_stat_sheets')
            .select()
            .eq('user_id', lic.licensorNoraId!)
            .maybeSingle();
        if (s != null) stats = StatSheet.fromJson(s);
      }

      return UnlockedCharacter(
        licenseId: lic.licenseId,
        licensorNoraId: lic.licensorNoraId,
        displayName:
            reg['licensor_display_name'] as String? ?? 'Licensed Creator',
        portraitUrl: reg['licensor_image_url'] as String?,
        category: reg['listing_category'] as String? ?? 'creator',
        archetype: UnlockedCharacter.archetypeFor(stats: stats),
        stats: stats,
        expiresAt: lic.expirationDate == null
            ? null
            : DateTime.tryParse(lic.expirationDate!),
      );
    } catch (e) {
      debugPrint('[LicenseSync] build failed for ${lic.licenseId}: $e');
      return null;
    }
  }
}
