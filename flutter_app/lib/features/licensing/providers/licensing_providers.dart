import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ─── Marketplace search args ──────────────────────────────────────────────────
// Immutable value type so FutureProvider.family dedups identical searches.
class LicenseSearchArgs {
  final String query;
  final String? category; // null = all categories
  const LicenseSearchArgs({this.query = '', this.category});

  @override
  bool operator ==(Object other) =>
      other is LicenseSearchArgs &&
      other.query == query &&
      other.category == category;

  @override
  int get hashCode => Object.hash(query, category);
}

// ─── Marketplace listing search (full-text + category filter) ─────────────────
// Active listings only (RLS enforces this too). Tiers are joined so cards can
// show a "from $X" price without a second round-trip.
final licenseListingsProvider = FutureProvider.family
    .autoDispose<List<Map<String, dynamic>>, LicenseSearchArgs>(
        (ref, args) async {
  var query = Supabase.instance.client
      .from('lkn_listings')
      .select(
        'id, listing_title, listing_description, licensor_display_name, '
        'licensor_image_url, category, featured, published_at, '
        'covers_name, covers_image, covers_voice, covers_signature, covers_persona, '
        'lkn_license_tiers!listing_id(id, tier_name, price_usd_cents, is_active)',
      )
      .eq('status', 'active');

  if (args.category != null && args.category!.isNotEmpty) {
    query = query.eq('category', args.category!);
  }
  final trimmed = args.query.trim();
  if (trimmed.isNotEmpty) {
    // websearch_to_tsquery via PostgREST textSearch on the FTS column.
    query = query.textSearch('search_vector', trimmed, config: 'english');
  }

  final data = await query
      .order('featured', ascending: false)
      .order('published_at', ascending: false, nullsFirst: false)
      .limit(60);
  return List<Map<String, dynamic>>.from(data as List);
});

// ─── Single listing detail (listing + tiers + per-tier template) ──────────────
// Returns null if the listing is not active / not found. Tiers carry their
// template (permitted uses, restrictions, duration, territory) for the detail
// page's "what's allowed" visuals and the checkout terms.
final licenseListingDetailProvider = FutureProvider.family
    .autoDispose<Map<String, dynamic>?, String>((ref, listingId) async {
  final data = await Supabase.instance.client
      .from('lkn_listings')
      .select(
        '*, '
        'lkn_license_tiers!listing_id(*), '
        'lkn_license_templates!listing_id(*)',
      )
      .eq('id', listingId)
      .eq('status', 'active')
      .maybeSingle();
  return data;
});

// ─── Licenses held by the current user (My Licenses) ──────────────────────────
final myLicensesProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return [];
  final data = await Supabase.instance.client
      .from('lkn_agreements')
      .select(
        'id, license_id, status, effective_date, expiration_date, '
        'price_paid_usd_cents, is_simulated, created_at, '
        'lkn_listings!listing_id(listing_title, licensor_display_name, '
        'licensor_image_url, category), '
        'lkn_license_tiers!tier_id(tier_name)',
      )
      .eq('licensee_user_id', userId)
      .order('created_at', ascending: false);
  return List<Map<String, dynamic>>.from(data as List);
});

// ─── Public license record (lkn_public_registry) — no auth, no PII ────────────
final publicLicenseRecordProvider = FutureProvider.family
    .autoDispose<Map<String, dynamic>?, String>((ref, licenseId) async {
  final data = await Supabase.instance.client
      .from('lkn_public_registry')
      .select()
      .eq('license_id', licenseId)
      .maybeSingle();
  return data;
});
