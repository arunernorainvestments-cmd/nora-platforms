import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../licensing_format.dart';
import '../providers/licensing_providers.dart';
import '../../../core/widgets/n_back_button.dart';

/// Public landing page for the Right of Publicity Licensing Marketplace.
/// Search + category filter against active lkn_listings.
class LicensingMarketplaceHomeScreen extends ConsumerStatefulWidget {
  const LicensingMarketplaceHomeScreen({super.key});

  @override
  ConsumerState<LicensingMarketplaceHomeScreen> createState() =>
      _LicensingMarketplaceHomeScreenState();
}

class _LicensingMarketplaceHomeScreenState
    extends ConsumerState<LicensingMarketplaceHomeScreen> {
  final _searchController = TextEditingController();
  Timer? _debounce;
  String _query = '';
  String? _category;

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  void _onSearchChanged(String value) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () {
      if (mounted) setState(() => _query = value);
    });
  }

  @override
  Widget build(BuildContext context) {
    final isLoggedIn =
        Supabase.instance.client.auth.currentUser != null;
    final args = LicenseSearchArgs(query: _query, category: _category);
    final listingsAsync = ref.watch(licenseListingsProvider(args));
    final width = MediaQuery.of(context).size.width;
    final crossAxisCount = width >= 1100
        ? 3
        : width >= 720
            ? 2
            : 1;

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: const NBackButton(fallback: '/home'),
        backgroundColor: AppTheme.surface,
        title: const Text('Licensing',
            style: TextStyle(color: AppTheme.textPrimary)),
        iconTheme: const IconThemeData(color: AppTheme.textPrimary),
        actions: [
          if (isLoggedIn)
            TextButton(
              onPressed: () => context.push('/my-licenses'),
              child: const Text('My Licenses'),
            ),
        ],
      ),
      body: RefreshIndicator(
        color: AppTheme.primary,
        backgroundColor: AppTheme.surface,
        onRefresh: () async => ref.invalidate(licenseListingsProvider(args)),
        child: CustomScrollView(
          slivers: [
            SliverToBoxAdapter(child: _Hero(isLoggedIn: isLoggedIn)),
            SliverToBoxAdapter(child: _searchBar()),
            SliverToBoxAdapter(child: _categoryChips()),
            listingsAsync.when(
              loading: () => const SliverFillRemaining(
                hasScrollBody: false,
                child: Center(
                    child: CircularProgressIndicator(color: AppTheme.primary)),
              ),
              error: (e, _) => SliverFillRemaining(
                hasScrollBody: false,
                child: _Message('Could not load listings.\n$e'),
              ),
              data: (listings) {
                if (listings.isEmpty) {
                  return const SliverFillRemaining(
                    hasScrollBody: false,
                    child: _Message(
                        'No listings match your search yet. Try a different name or category.'),
                  );
                }
                return SliverPadding(
                  padding: const EdgeInsets.all(16),
                  sliver: SliverGrid(
                    gridDelegate:
                        SliverGridDelegateWithFixedCrossAxisCount(
                      crossAxisCount: crossAxisCount,
                      mainAxisSpacing: 16,
                      crossAxisSpacing: 16,
                      mainAxisExtent: 220,
                    ),
                    delegate: SliverChildBuilderDelegate(
                      (context, i) =>
                          _LicensingListingCard(listing: listings[i]),
                      childCount: listings.length,
                    ),
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _searchBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: TextField(
        controller: _searchController,
        onChanged: _onSearchChanged,
        style: const TextStyle(color: AppTheme.textPrimary),
        decoration: InputDecoration(
          hintText: 'Search licensors, names, keywords…',
          prefixIcon:
              const Icon(Icons.search, color: AppTheme.textSecondary),
          suffixIcon: _searchController.text.isEmpty
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear,
                      color: AppTheme.textSecondary),
                  onPressed: () {
                    _searchController.clear();
                    setState(() => _query = '');
                  },
                ),
          filled: true,
          fillColor: AppTheme.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppTheme.cardBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: const BorderSide(color: AppTheme.cardBorder),
          ),
        ),
      ),
    );
  }

  Widget _categoryChips() {
    return SizedBox(
      height: 44,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        children: [
          _chip('All', _category == null, () => setState(() => _category = null)),
          ...LicensingFormat.categoryKeys.map((k) => _chip(
                LicensingFormat.categoryLabel(k),
                _category == k,
                () => setState(() => _category = k),
              )),
        ],
      ),
    );
  }

  Widget _chip(String label, bool selected, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.only(right: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        onSelected: (_) => onTap(),
        backgroundColor: AppTheme.surface,
        selectedColor: AppTheme.primary.withValues(alpha: 0.25),
        side: BorderSide(
            color: selected ? AppTheme.primary : AppTheme.cardBorder),
        labelStyle: TextStyle(
          color: selected ? AppTheme.primary : AppTheme.textSecondary,
          fontWeight: FontWeight.w600,
          fontSize: 13,
        ),
      ),
    );
  }
}

class _Hero extends StatelessWidget {
  final bool isLoggedIn;
  const _Hero({required this.isLoggedIn});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 20),
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [AppTheme.primary, AppTheme.secondary],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'License real likeness and image rights, verified on N.O.R.A. Platforms.',
            style: TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'Right of Publicity licensing for AI, advertising, games, and more — '
            'every license cryptographically verifiable via API.',
            style: TextStyle(color: Colors.white70, fontSize: 14, height: 1.4),
          ),
          const SizedBox(height: 16),
          Wrap(
            spacing: 12,
            runSpacing: 8,
            children: [
              FilledButton.tonal(
                onPressed: () => context.push('/create-listing'),
                style: FilledButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: AppTheme.primary,
                ),
                child: const Text('List your likeness'),
              ),
              OutlinedButton(
                onPressed: () => context.push('/partners'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: Colors.white,
                  side: const BorderSide(color: Colors.white70),
                ),
                child: const Text('For management & labels'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _LicensingListingCard extends StatelessWidget {
  final Map<String, dynamic> listing;
  const _LicensingListingCard({required this.listing});

  int? _minPriceCents() {
    final tiers = (listing['lkn_license_tiers'] as List?) ?? const [];
    final prices = tiers
        .where((t) => t['is_active'] == true)
        .map((t) => (t['price_usd_cents'] as num?)?.toInt())
        .whereType<int>()
        .toList();
    if (prices.isEmpty) return null;
    return prices.reduce((a, b) => a < b ? a : b);
  }

  @override
  Widget build(BuildContext context) {
    final imageUrl = listing['licensor_image_url'] as String?;
    final minCents = _minPriceCents();
    final rights = LicensingFormat.coveredRights(listing);

    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => context.push('/licenses/${listing['id']}'),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: listing['featured'] == true
                ? AppTheme.primary.withValues(alpha: 0.5)
                : AppTheme.cardBorder,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundColor: AppTheme.primary.withValues(alpha: 0.2),
                  backgroundImage:
                      imageUrl != null ? NetworkImage(imageUrl) : null,
                  child: imageUrl == null
                      ? const Icon(Icons.person, color: AppTheme.primary)
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        listing['licensor_display_name'] as String? ?? '',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      Text(
                        LicensingFormat.categoryLabel(
                            listing['category'] as String?),
                        style: const TextStyle(
                            color: AppTheme.textSecondary, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: Text(
                listing['listing_title'] as String? ?? '',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppTheme.textPrimary, fontSize: 14, height: 1.3),
              ),
            ),
            if (rights.isNotEmpty)
              Text(
                'Covers: ${rights.join(', ')}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 12),
              ),
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  minCents == null
                      ? 'No tiers'
                      : 'From ${LicensingFormat.price(minCents)}',
                  style: const TextStyle(
                    color: AppTheme.secondary,
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                  ),
                ),
                const Icon(Icons.arrow_forward,
                    size: 18, color: AppTheme.textSecondary),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _Message extends StatelessWidget {
  final String text;
  const _Message(this.text);

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Text(
          text,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14),
        ),
      ),
    );
  }
}
