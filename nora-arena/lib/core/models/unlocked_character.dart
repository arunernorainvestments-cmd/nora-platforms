import 'stat_sheet.dart';

/// A playable fighter produced by importing a licensed likeness.
///
/// Built by [LicenseSyncService] from: a verified active license (ownership) +
/// public-registry display assets (portrait, name, category) + the creator's
/// stat sheet (battle numbers). The Flame layer renders the [archetype] Rive rig
/// personalized with [portraitUrl] + stat-driven modifiers (see ARCHITECTURE.md).
class UnlockedCharacter {
  final String licenseId;
  final String? licensorNoraId;
  final String displayName;
  final String? portraitUrl; // the licensed likeness image (from public registry)
  final String category; // listing category (music, entertainment, ...)
  final String archetype; // which battle rig to load
  final StatSheet? stats;
  final DateTime? expiresAt;

  const UnlockedCharacter({
    required this.licenseId,
    required this.licensorNoraId,
    required this.displayName,
    required this.portraitUrl,
    required this.category,
    required this.archetype,
    required this.stats,
    required this.expiresAt,
  });

  /// asset path for the battle rig — see CLAUDE.md asset naming.
  String get rigAsset => 'assets/battle/rive/$archetype.riv';

  String? get expiryLabel {
    if (expiresAt == null) return null;
    final d = expiresAt!;
    return 'Valid until ${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  /// One archetype rig is reused for every imported creator. Mapping priority:
  /// 1) explicit creator archetype (if/when the backend assigns one),
  /// 2) dominant stat, 3) a neutral all-rounder.
  /// NOTE: creator_stat_sheets has no archetype column today (migration 080) —
  /// finalize this mapping against the live archetype set (doc3 / migration 043)
  /// during the battle-game phase.
  static String archetypeFor({String? explicitArchetype, StatSheet? stats}) {
    if (explicitArchetype != null && explicitArchetype.isNotEmpty) {
      return explicitArchetype;
    }
    switch (stats?.dominantStat) {
      case 'power':
        return 'bruiser';
      case 'charisma':
        return 'charmer';
      case 'resilience':
        return 'guardian';
      case 'agility':
        return 'striker';
      case 'wit':
        return 'tactician';
      case 'influence':
        return 'icon';
      default:
        return 'allrounder';
    }
  }
}
