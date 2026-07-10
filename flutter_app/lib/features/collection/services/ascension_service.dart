import 'package:supabase_flutter/supabase_flutter.dart';

/// Client for the weekly tier-ascension refresh (`chit-ascension` edge function,
/// migs 136/157 — "the viral upgrade"). The function re-reads the linked posts'
/// LIVE engagement through the ownership-checked platform readers, then runs the
/// server-side refresh: one-directional tier-ups, big jumps (≥3 ranks) go to a
/// manual review queue, listed chits are frozen. Once per 7 days per user.
class AscensionService {
  static SupabaseClient get _client => Supabase.instance.client;

  static Future<AscensionResult> refresh() async {
    try {
      final res =
          await _client.functions.invoke('chit-ascension', body: const {});
      return AscensionResult.fromMap(Map<String, dynamic>.from(res.data as Map));
    } on FunctionException catch (e) {
      final d = e.details;
      if (d is Map && d['error'] == 'ascension_cooldown') {
        throw AscensionCooldownException(
            DateTime.tryParse(d['next_refresh_at']?.toString() ?? ''));
      }
      throw AscensionException(_messageFrom(e));
    }
  }

  static String _messageFrom(FunctionException e) {
    final d = e.details;
    if (d is Map) {
      final msg = d['detail'] ?? d['error'];
      if (msg != null) return msg.toString();
    }
    return 'Request failed (${e.status})';
  }
}

/// One chit that moved (or was queued to move) up the ladder this refresh.
class AscensionTierUp {
  const AscensionTierUp({
    required this.chitId,
    required this.name,
    required this.fromTier,
    required this.toTier,
  });

  final String chitId;
  final String name;
  final String fromTier;
  final String toTier;

  factory AscensionTierUp.fromMap(Map<dynamic, dynamic> m) => AscensionTierUp(
        chitId: (m['chit_id'] ?? '').toString(),
        name: (m['name'] ?? 'BattleChit').toString(),
        fromTier: (m['from_tier'] ?? '?').toString(),
        toTier: (m['to_tier'] ?? '?').toString(),
      );
}

class AscensionResult {
  const AscensionResult({
    required this.tierUps,
    required this.queuedForReview,
    required this.momentsSynced,
    required this.nextRefreshAt,
    required this.detail,
  });

  /// Chits that ascended in place this refresh.
  final List<AscensionTierUp> tierUps;

  /// Big jumps (≥3 ranks) held for manual review — tier unchanged until approved.
  final List<AscensionTierUp> queuedForReview;

  /// How many moments had their live engagement re-read.
  final int momentsSynced;

  /// When the next refresh unlocks; null when this call didn't burn the window
  /// (e.g. nothing ascendable).
  final DateTime? nextRefreshAt;

  /// Server-provided note (e.g. "No ascendable chits — mint one first").
  final String? detail;

  bool get anythingHappened => tierUps.isNotEmpty || queuedForReview.isNotEmpty;

  factory AscensionResult.fromMap(Map<String, dynamic> m) => AscensionResult(
        tierUps: ((m['ascensions'] as List?) ?? const [])
            .map((e) => AscensionTierUp.fromMap(e as Map))
            .toList(),
        queuedForReview: ((m['queued'] as List?) ?? const [])
            .map((e) => AscensionTierUp.fromMap(e as Map))
            .toList(),
        momentsSynced: (m['moments_synced'] as num?)?.toInt() ?? 0,
        nextRefreshAt: m['next_refresh_at'] == null
            ? null
            : DateTime.tryParse(m['next_refresh_at'].toString()),
        detail: m['detail']?.toString(),
      );
}

class AscensionException implements Exception {
  const AscensionException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The weekly window is still closed; [nextRefreshAt] says when it reopens.
class AscensionCooldownException implements Exception {
  const AscensionCooldownException(this.nextRefreshAt);
  final DateTime? nextRefreshAt;
  @override
  String toString() => 'Ascension refresh is available once per 7 days';
}
