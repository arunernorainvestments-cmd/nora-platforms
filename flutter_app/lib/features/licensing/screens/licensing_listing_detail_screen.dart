import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../licensing_format.dart';
import '../providers/licensing_providers.dart';
import '../../../core/widgets/n_back_button.dart';

/// Detail page for a single marketplace listing. Shows the licensor, the
/// rights covered, and each priced tier with its permitted-uses / restrictions.
class LicensingListingDetailScreen extends ConsumerWidget {
  final String listingId;
  const LicensingListingDetailScreen({super.key, required this.listingId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final detailAsync = ref.watch(licenseListingDetailProvider(listingId));

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: const NBackButton(fallback: '/licenses'),
        backgroundColor: AppTheme.surface,
        title: const Text('License Listing',
            style: TextStyle(color: AppTheme.textPrimary)),
        iconTheme: const IconThemeData(color: AppTheme.textPrimary),
      ),
      body: detailAsync.when(
        loading: () => const Center(
            child: CircularProgressIndicator(color: AppTheme.primary)),
        error: (e, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Text('Could not load listing.\n$e',
                textAlign: TextAlign.center,
                style: const TextStyle(color: AppTheme.textSecondary)),
          ),
        ),
        data: (listing) {
          if (listing == null) {
            return const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'This listing is no longer available.',
                  style: TextStyle(color: AppTheme.textSecondary),
                ),
              ),
            );
          }
          return _Body(listingId: listingId, listing: listing);
        },
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final String listingId;
  final Map<String, dynamic> listing;
  const _Body({required this.listingId, required this.listing});

  @override
  Widget build(BuildContext context) {
    final tiers = ((listing['lkn_license_tiers'] as List?) ?? const [])
        .cast<Map<String, dynamic>>()
        .where((t) => t['is_active'] == true)
        .toList()
      ..sort((a, b) => ((a['price_usd_cents'] as num?) ?? 0)
          .compareTo((b['price_usd_cents'] as num?) ?? 0));
    final templates = ((listing['lkn_license_templates'] as List?) ?? const [])
        .cast<Map<String, dynamic>>();
    final templateByTier = {
      for (final t in templates) t['tier_id'] as String?: t,
    };
    final imageUrl = listing['licensor_image_url'] as String?;
    final rights = LicensingFormat.coveredRights(listing);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 760),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Row(
              children: [
                CircleAvatar(
                  radius: 36,
                  backgroundColor: AppTheme.primary.withValues(alpha: 0.2),
                  backgroundImage:
                      imageUrl != null ? NetworkImage(imageUrl) : null,
                  child: imageUrl == null
                      ? const Icon(Icons.person,
                          color: AppTheme.primary, size: 36)
                      : null,
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        listing['licensor_display_name'] as String? ?? '',
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        LicensingFormat.categoryLabel(
                            listing['category'] as String?),
                        style: const TextStyle(
                            color: AppTheme.textSecondary, fontSize: 14),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 20),
            Text(
              listing['listing_title'] as String? ?? '',
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            if ((listing['listing_description'] as String?)?.isNotEmpty ??
                false) ...[
              const SizedBox(height: 8),
              Text(
                listing['listing_description'] as String,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 14, height: 1.5),
              ),
            ],
            const SizedBox(height: 20),
            if (rights.isNotEmpty) ...[
              const _SectionTitle('Rights covered'),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: rights
                    .map((r) => Chip(
                          label: Text(r),
                          backgroundColor:
                              AppTheme.primary.withValues(alpha: 0.12),
                          labelStyle: const TextStyle(
                              color: AppTheme.primary,
                              fontWeight: FontWeight.w600),
                          side: BorderSide(
                              color:
                                  AppTheme.primary.withValues(alpha: 0.3)),
                        ))
                    .toList(),
              ),
              const SizedBox(height: 24),
            ],
            const _SectionTitle('License tiers'),
            const SizedBox(height: 12),
            if (tiers.isEmpty)
              const Text('No tiers are available for this listing.',
                  style: TextStyle(color: AppTheme.textSecondary))
            else
              ...tiers.map((tier) => _TierCard(
                    listingId: listingId,
                    tier: tier,
                    template: templateByTier[tier['id'] as String?],
                  )),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

class _TierCard extends StatelessWidget {
  final String listingId;
  final Map<String, dynamic> tier;
  final Map<String, dynamic>? template;
  const _TierCard({
    required this.listingId,
    required this.tier,
    required this.template,
  });

  @override
  Widget build(BuildContext context) {
    final purposes =
        template == null ? <String>[] : LicensingFormat.permittedPurposes(template!);
    final restrictions =
        template == null ? <String>[] : LicensingFormat.restrictions(template!);
    final maxLicenses = (tier['max_licenses'] as num?)?.toInt();
    final sold = (tier['licenses_sold'] as num?)?.toInt() ?? 0;
    final soldOut = maxLicenses != null && sold >= maxLicenses;

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: tier['is_exclusive'] == true
              ? AppTheme.secondary.withValues(alpha: 0.5)
              : AppTheme.cardBorder,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Text(
                          tier['tier_name'] as String? ?? 'Tier',
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        if (tier['is_exclusive'] == true) ...[
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 8, vertical: 2),
                            decoration: BoxDecoration(
                              color: AppTheme.secondary.withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: const Text('Exclusive',
                                style: TextStyle(
                                    color: AppTheme.secondary,
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700)),
                          ),
                        ],
                      ],
                    ),
                    if ((tier['tier_description'] as String?)?.isNotEmpty ??
                        false) ...[
                      const SizedBox(height: 4),
                      Text(tier['tier_description'] as String,
                          style: const TextStyle(
                              color: AppTheme.textSecondary, fontSize: 13)),
                    ],
                  ],
                ),
              ),
              Text(
                LicensingFormat.price(tier['price_usd_cents'] as num?),
                style: const TextStyle(
                  color: AppTheme.secondary,
                  fontSize: 20,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          if (template != null) ...[
            const SizedBox(height: 14),
            _MetaRow(
                icon: Icons.schedule,
                text: LicensingFormat.durationLabel(template!)),
            _MetaRow(
                icon: Icons.public,
                text: LicensingFormat.territoryLabel(
                    template!['territory'] as String?)),
            if (purposes.isNotEmpty) ...[
              const SizedBox(height: 12),
              _MiniList(
                title: 'Permitted uses',
                items: purposes,
                color: AppTheme.success,
                icon: Icons.check_circle_outline,
              ),
            ],
            if (restrictions.isNotEmpty) ...[
              const SizedBox(height: 10),
              _MiniList(
                title: 'Restrictions',
                items: restrictions,
                color: AppTheme.danger,
                icon: Icons.block,
              ),
            ],
          ],
          if (maxLicenses != null) ...[
            const SizedBox(height: 12),
            Text('$sold of $maxLicenses sold',
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 12)),
          ],
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: soldOut
                  ? null
                  : () => context.push(
                      '/licenses/$listingId/buy/${tier['id']}'),
              child: Text(soldOut ? 'Sold out' : 'Buy this license'),
            ),
          ),
        ],
      ),
    );
  }
}

class _MetaRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _MetaRow({required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        children: [
          Icon(icon, size: 15, color: AppTheme.textSecondary),
          const SizedBox(width: 8),
          Text(text,
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 13)),
        ],
      ),
    );
  }
}

class _MiniList extends StatelessWidget {
  final String title;
  final List<String> items;
  final Color color;
  final IconData icon;
  const _MiniList({
    required this.title,
    required this.items,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title,
            style: TextStyle(
                color: color, fontSize: 13, fontWeight: FontWeight.w600)),
        const SizedBox(height: 6),
        ...items.map((i) => Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(icon, size: 14, color: color),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(i,
                        style: const TextStyle(
                            color: AppTheme.textPrimary, fontSize: 13)),
                  ),
                ],
              ),
            )),
      ],
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: AppTheme.textPrimary,
        fontSize: 16,
        fontWeight: FontWeight.bold,
      ),
    );
  }
}
