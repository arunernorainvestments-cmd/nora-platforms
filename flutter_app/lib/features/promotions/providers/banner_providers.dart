import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/promotion_banner.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Active promotion banners (universe + galaxy), non-cancelled, non-expired.
// Used by the home ticker and for seeding the flash overlay on app open.
// ─────────────────────────────────────────────────────────────────────────────

final activePromotionBannersProvider =
    FutureProvider.autoDispose<List<PromotionBanner>>((ref) async {
  final now = DateTime.now().toUtc().toIso8601String();
  final data = await Supabase.instance.client
      .from('promotion_banners')
      .select(
        'id, type, target_user_id, target_username, category, expires_at, is_cancelled, created_at',
      )
      .eq('is_cancelled', false)
      .gt('expires_at', now)
      .order('created_at', ascending: false);

  return (data as List)
      .map((e) => PromotionBanner.fromJson(e as Map<String, dynamic>))
      .toList();
});

// ─────────────────────────────────────────────────────────────────────────────
// Categories the current user has open bets on (for Galaxy filtering).
// A Galaxy banner is shown to a user only if their open bets include a MM
// whose category_1 matches the Galaxy's category.
// ─────────────────────────────────────────────────────────────────────────────

final userBetCategoriesProvider =
    FutureProvider.autoDispose<Set<String>>((ref) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return {};

  // Step 1: market ids from this user's bets
  final betsData = await Supabase.instance.client
      .from('bets')
      .select('market_id')
      .eq('user_id', userId);

  final marketIds = (betsData as List)
      .map((b) => b['market_id'] as String?)
      .whereType<String>()
      .toList();

  if (marketIds.isEmpty) return {};

  // Step 2: open markets from those ids, with their creator's category_1
  final marketsData = await Supabase.instance.client
      .from('markets')
      .select('creator_id')
      .eq('status', 'open')
      .inFilter('id', marketIds);

  final creatorIds = (marketsData as List)
      .map((m) => m['creator_id'] as String?)
      .whereType<String>()
      .toList();

  if (creatorIds.isEmpty) return {};

  // Step 3: category_1 of those creators
  final profilesData = await Supabase.instance.client
      .from('profiles')
      .select('category_1')
      .inFilter('id', creatorIds);

  return (profilesData as List)
      .map((p) => p['category_1'] as String?)
      .whereType<String>()
      .toSet();
});
