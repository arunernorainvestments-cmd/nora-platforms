import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Mystery Pool surfaces — Collections spec Phase N6, §1.5, gate G-MYSTERY.
///
/// The pool lets a Market Maker sell a slice of a collection's copies to the
/// platform at a fixed config rate; those copies become gameplay rewards. The
/// whole feature ships behind `mystery_pool_settings.mode` and is DISABLED in
/// beta — the UI shows the button with an explainer and no action.
///
/// Boxes are never purchasable. There is no buy path in this file because there
/// is no buy path in the backend: grants come only from server-side gameplay
/// hooks (mig 175, `mystery_box_grant` is REVOKEd from `authenticated`).

/// `disabled` (beta default) · `sim` · `live`.
final mysteryPoolModeProvider =
    FutureProvider.autoDispose<String>((ref) async {
  final res = await Supabase.instance.client
      .from('mystery_pool_settings')
      .select('mode')
      .maybeSingle();
  return (res?['mode'] as String?) ?? 'disabled';
});

/// Per-tier platform purchase rate, in integer USD cents (never floats).
final mysteryPoolRatesProvider =
    FutureProvider.autoDispose<Map<String, int>>((ref) async {
  final rows = await Supabase.instance.client
      .from('mystery_pool_tier_config')
      .select('tier, submit_payout_cents');
  return {
    for (final r in rows as List)
      r['tier'] as String: r['submit_payout_cents'] as int,
  };
});

/// Boxes this user has been awarded (append-only grant ledger, own rows only).
final myMysteryGrantsProvider =
    FutureProvider.autoDispose<List<MysteryGrant>>((ref) async {
  final rows = await Supabase.instance.client
      .from('mystery_box_grants')
      .select('id, chit_id, tier, was_generic, created_at')
      .order('created_at', ascending: false)
      .limit(50);
  return [for (final r in rows as List) MysteryGrant.fromRow(r)];
});

class MysteryGrant {
  const MysteryGrant({
    required this.id,
    required this.chitId,
    required this.tier,
    required this.wasGeneric,
    required this.createdAt,
  });

  final String id;
  final String chitId;
  final String tier;
  final bool wasGeneric;
  final DateTime createdAt;

  factory MysteryGrant.fromRow(Map<String, dynamic> r) => MysteryGrant(
        id: r['id'] as String,
        chitId: r['chit_id'] as String,
        tier: r['tier'] as String,
        wasGeneric: r['was_generic'] == true,
        createdAt: DateTime.parse(r['created_at'] as String),
      );
}

class MysteryPoolService {
  static SupabaseClient get _client => Supabase.instance.client;

  /// Submit `copies` of a collection card to the pool. Server enforces the
  /// minter check, the per-card cap, and the gate; it pays on acceptance.
  /// Unreachable while mode is `disabled` — the RPC RAISEs.
  static Future<String> submit({
    required String collectionId,
    required String chitId,
    int copies = 1,
  }) async {
    final res = await _client.rpc('mystery_pool_submit', params: {
      'p_collection': collectionId,
      'p_chit_id': chitId,
      'p_copies': copies,
    });
    return res as String;
  }

  static String errorMessage(Object e) {
    final s = e.toString();
    if (s.contains('beta-disabled')) {
      return 'The Mystery Box pool is not open yet.';
    }
    if (s.contains('Submission cap reached')) {
      return 'You have already submitted the maximum share of this card.';
    }
    if (s.contains('Only the collection minter')) {
      return 'Only the collection minter can submit its cards.';
    }
    if (s.contains('cannot submit')) {
      return 'You do not hold enough copies to submit.';
    }
    return 'Could not submit to the pool. Please try again.';
  }
}
