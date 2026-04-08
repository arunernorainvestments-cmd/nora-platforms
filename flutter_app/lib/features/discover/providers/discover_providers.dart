import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ─────────────────────────────────────────────────────────────────────────────
// MODELS
// ─────────────────────────────────────────────────────────────────────────────

class FamousCreator {
  final String id;
  final String name;
  final String slug;
  final String? bio;
  final String? platformYoutube;
  final String? platformTiktok;
  final String? platformX;
  final String? platformTwitch;
  final String? platformKick;
  final String? platformInstagram;
  final int totalFollowers;

  const FamousCreator({
    required this.id,
    required this.name,
    required this.slug,
    this.bio,
    this.platformYoutube,
    this.platformTiktok,
    this.platformX,
    this.platformTwitch,
    this.platformKick,
    this.platformInstagram,
    required this.totalFollowers,
  });

  factory FamousCreator.fromJson(Map<String, dynamic> json) => FamousCreator(
        id: json['id'] as String,
        name: json['name'] as String,
        slug: json['slug'] as String,
        bio: json['bio'] as String?,
        platformYoutube: json['platform_youtube'] as String?,
        platformTiktok: json['platform_tiktok'] as String?,
        platformX: json['platform_x'] as String?,
        platformTwitch: json['platform_twitch'] as String?,
        platformKick: json['platform_kick'] as String?,
        platformInstagram: json['platform_instagram'] as String?,
        totalFollowers: (json['total_followers'] as num?)?.toInt() ?? 0,
      );

  /// Returns only the platforms that have a non-null handle.
  List<({String label, String handle})> get activePlatforms => [
        if (platformYoutube != null) (label: 'YT', handle: platformYoutube!),
        if (platformTiktok != null) (label: 'TT', handle: platformTiktok!),
        if (platformX != null) (label: 'X', handle: platformX!),
        if (platformTwitch != null) (label: 'Twitch', handle: platformTwitch!),
        if (platformKick != null) (label: 'Kick', handle: platformKick!),
        if (platformInstagram != null) (label: 'IG', handle: platformInstagram!),
      ];
}

class RisingCreator {
  final String id;
  final String? displayName;
  final String? username;
  final String? avatarUrl;
  final double popularityScore;
  final double? spotlightScore;
  final String? spotlightTier; // 'on_fire' | 'rising' | 'watched' | 'listed'
  final int availableTokens;

  const RisingCreator({
    required this.id,
    this.displayName,
    this.username,
    this.avatarUrl,
    required this.popularityScore,
    this.spotlightScore,
    this.spotlightTier,
    required this.availableTokens,
  });

  factory RisingCreator.fromJson(Map<String, dynamic> json) {
    // PostgREST returns reverse FK embeds as arrays; handle both array and
    // single-object shapes defensively since the PK/FK coincide on these tables.
    Map<String, dynamic>? unwrap(dynamic raw) {
      if (raw is List && raw.isNotEmpty) {
        return raw.first as Map<String, dynamic>;
      }
      if (raw is Map<String, dynamic>) return raw;
      return null;
    }

    final spotlight = unwrap(json['spotlight_scores']);
    final balance = unwrap(json['token_balances']);

    return RisingCreator(
      id: json['id'] as String,
      displayName: json['display_name'] as String?,
      username: json['username'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      popularityScore: (json['popularity_score'] as num?)?.toDouble() ?? 0,
      spotlightScore: (spotlight?['score'] as num?)?.toDouble(),
      spotlightTier: spotlight?['tier'] as String?,
      availableTokens: (balance?['available_tokens'] as num?)?.toInt() ?? 0,
    );
  }

  String get displayLabel => displayName ?? username ?? 'Anonymous';

  String get initials {
    final label = displayLabel;
    return label.isNotEmpty ? label[0].toUpperCase() : '?';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PROVIDERS
// ─────────────────────────────────────────────────────────────────────────────

final famousCreatorsProvider = FutureProvider<List<FamousCreator>>((ref) async {
  final data = await Supabase.instance.client
      .from('famous_creators')
      .select()
      .order('total_followers', ascending: false);
  return (data as List)
      .map((e) => FamousCreator.fromJson(e as Map<String, dynamic>))
      .toList();
});

// Lightweight set of user_ids currently live — watched by Famous + Rising tabs
// to conditionally render the Live Now badge.
final liveUserIdsProvider = FutureProvider.autoDispose<Set<String>>((ref) async {
  final res = await Supabase.instance.client
      .from('platform_metrics')
      .select('user_id')
      .eq('is_live', true);
  return (res as List).map((e) => e['user_id'] as String).toSet();
});

final risingCreatorsProvider = FutureProvider<List<RisingCreator>>((ref) async {
  final data = await Supabase.instance.client
      .from('profiles')
      .select('id, display_name, username, avatar_url, popularity_score, '
          'spotlight_scores(score, tier), token_balances(available_tokens)')
      .eq('is_creator', true)
      .order('created_at', ascending: false);
  return (data as List)
      .map((e) => RisingCreator.fromJson(e as Map<String, dynamic>))
      .toList();
});
