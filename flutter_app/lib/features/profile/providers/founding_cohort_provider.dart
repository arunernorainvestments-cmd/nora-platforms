import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A Founding Market Maker and the card they minted (Playset spec S4.2).
///
/// The cohort is the launch distribution engine: 10–25 creators white-gloved
/// through KYC + social link + their own mint before public launch, so that on
/// day one the market surface shows real people with real cards. The badge is
/// cosmetic — it grants nothing in-game.
class FoundingMarketMaker {
  const FoundingMarketMaker({
    required this.userId,
    required this.displayName,
    this.avatarUrl,
    this.chitId,
    this.chitName,
    this.tier,
    this.cardArtUrl,
    this.revealAssetUrl,
  });

  final String userId;
  final String displayName;
  final String? avatarUrl;
  final String? chitId;
  final String? chitName;
  final String? tier;
  final String? cardArtUrl;
  final String? revealAssetUrl;

  factory FoundingMarketMaker.fromRow(Map<String, dynamic> r) =>
      FoundingMarketMaker(
        userId: r['user_id'] as String,
        displayName: (r['display_name'] ?? 'Founding Market Maker').toString(),
        avatarUrl: r['avatar_url'] as String?,
        chitId: r['chit_id'] as String?,
        chitName: r['chit_name'] as String?,
        tier: r['tier'] as String?,
        cardArtUrl: r['card_art_url'] as String?,
        revealAssetUrl: r['reveal_asset_url'] as String?,
      );
}

/// The launch-day featured row. Public (the showcase RPC is granted to anon),
/// test accounts excluded server-side (Hard Rule 15).
final foundingCohortProvider =
    FutureProvider.autoDispose<List<FoundingMarketMaker>>((ref) async {
  final rows = await Supabase.instance.client
      .rpc('founding_market_maker_showcase', params: {'p_limit': 25});
  return (rows as List)
      .map((e) => FoundingMarketMaker.fromRow(
          Map<String, dynamic>.from(e as Map)))
      .toList();
});
