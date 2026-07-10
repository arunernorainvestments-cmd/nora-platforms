import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../licensing_format.dart';
import '../providers/licensing_providers.dart';
import '../../../core/widgets/n_back_button.dart';

/// Checkout for a single tier. Sim-mode purchase via lkn-purchase-license.
/// Live Stripe payments are not yet wired (function returns 501 in live mode).
class LicenseCheckoutScreen extends ConsumerStatefulWidget {
  final String listingId;
  final String tierId;
  const LicenseCheckoutScreen({
    super.key,
    required this.listingId,
    required this.tierId,
  });

  @override
  ConsumerState<LicenseCheckoutScreen> createState() =>
      _LicenseCheckoutScreenState();
}

class _LicenseCheckoutScreenState extends ConsumerState<LicenseCheckoutScreen> {
  bool _agreed = false;
  bool _submitting = false;

  Future<void> _purchase(Map<String, dynamic> tier) async {
    if (!_agreed || _submitting) return;
    setState(() => _submitting = true);
    try {
      final resp = await Supabase.instance.client.functions.invoke(
        'lkn-purchase-license',
        body: {'tier_id': widget.tierId, 'agreed': true},
      );
      final data = resp.data as Map<String, dynamic>?;
      final licenseId = data?['license_id'] as String?;
      if (licenseId == null) {
        throw Exception(data?['error'] ?? 'No license id returned');
      }
      if (!mounted) return;
      ref.invalidate(myLicensesProvider);
      _showSuccess(licenseId);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Purchase failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showSuccess(String licenseId) {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Row(
          children: [
            Icon(Icons.check_circle, color: AppTheme.success),
            SizedBox(width: 10),
            Text('License acquired',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 18)),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Your license is now active (simulated payment).',
                style: TextStyle(color: AppTheme.textSecondary)),
            const SizedBox(height: 12),
            SelectableText(licenseId,
                style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontFamily: 'monospace',
                    fontWeight: FontWeight.w600)),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              context.go('/license/$licenseId');
            },
            child: const Text('View public record'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              context.go('/my-licenses');
            },
            child: const Text('My Licenses'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final detailAsync =
        ref.watch(licenseListingDetailProvider(widget.listingId));

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: const NBackButton(fallback: '/licenses'),
        backgroundColor: AppTheme.surface,
        title: const Text('Checkout',
            style: TextStyle(color: AppTheme.textPrimary)),
        iconTheme: const IconThemeData(color: AppTheme.textPrimary),
      ),
      body: detailAsync.when(
        loading: () => const Center(
            child: CircularProgressIndicator(color: AppTheme.primary)),
        error: (e, _) => Center(
          child: Text('Could not load checkout.\n$e',
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textSecondary)),
        ),
        data: (listing) {
          if (listing == null) {
            return const Center(
                child: Text('This listing is no longer available.',
                    style: TextStyle(color: AppTheme.textSecondary)));
          }
          final tiers = ((listing['lkn_license_tiers'] as List?) ?? const [])
              .cast<Map<String, dynamic>>();
          final tier = tiers.where((t) => t['id'] == widget.tierId).firstOrNull;
          if (tier == null) {
            return const Center(
                child: Text('This tier is no longer available.',
                    style: TextStyle(color: AppTheme.textSecondary)));
          }
          final templates =
              ((listing['lkn_license_templates'] as List?) ?? const [])
                  .cast<Map<String, dynamic>>();
          final template =
              templates.where((t) => t['tier_id'] == widget.tierId).firstOrNull;
          return _Body(
            listing: listing,
            tier: tier,
            template: template,
            agreed: _agreed,
            submitting: _submitting,
            onAgreedChanged: (v) => setState(() => _agreed = v ?? false),
            onPurchase: () => _purchase(tier),
          );
        },
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final Map<String, dynamic> listing;
  final Map<String, dynamic> tier;
  final Map<String, dynamic>? template;
  final bool agreed;
  final bool submitting;
  final ValueChanged<bool?> onAgreedChanged;
  final VoidCallback onPurchase;

  const _Body({
    required this.listing,
    required this.tier,
    required this.template,
    required this.agreed,
    required this.submitting,
    required this.onAgreedChanged,
    required this.onPurchase,
  });

  @override
  Widget build(BuildContext context) {
    final priceCents = (tier['price_usd_cents'] as num?)?.toInt() ?? 0;
    final platformFee = (priceCents * 0.05).round();
    final contractHtml = template?['generated_contract_html'] as String?;
    final contractText = template?['generated_contract_text'] as String?;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 640),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            // ── Summary card ──
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.cardBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(listing['licensor_display_name'] as String? ?? '',
                      style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 2),
                  Text(
                    '${tier['tier_name'] ?? 'Tier'} · '
                    '${LicensingFormat.categoryLabel(listing['category'] as String?)}',
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 13),
                  ),
                  const Divider(color: AppTheme.cardBorder, height: 28),
                  _row('License price',
                      LicensingFormat.price(priceCents)),
                  _row('Platform fee (incl.)',
                      LicensingFormat.price(platformFee), muted: true),
                  if (template != null) ...[
                    const SizedBox(height: 8),
                    _row('Duration',
                        LicensingFormat.durationLabel(template!), muted: true),
                    _row(
                        'Territory',
                        LicensingFormat.territoryLabel(
                            template!['territory'] as String?),
                        muted: true),
                  ],
                  const Divider(color: AppTheme.cardBorder, height: 28),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Total',
                          style: TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 16,
                              fontWeight: FontWeight.bold)),
                      Text(LicensingFormat.price(priceCents),
                          style: const TextStyle(
                              color: AppTheme.secondary,
                              fontSize: 20,
                              fontWeight: FontWeight.bold)),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ── Terms ──
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.cardBorder),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('License agreement terms',
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.bold)),
                  const SizedBox(height: 12),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: SingleChildScrollView(
                      child: Text(
                        contractText ??
                            _strippedHtml(contractHtml) ??
                            'The full contract for this license will be generated and '
                                'attached to your agreement. By purchasing you agree to '
                                'the permitted uses and content restrictions shown on '
                                'the listing.',
                        style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 13,
                            height: 1.5),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),

            CheckboxListTile(
              value: agreed,
              onChanged: onAgreedChanged,
              controlAffinity: ListTileControlAffinity.leading,
              contentPadding: EdgeInsets.zero,
              activeColor: AppTheme.primary,
              title: const Text(
                'I agree to the N.O.R.A. license agreement terms.',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 14),
              ),
            ),
            const SizedBox(height: 4),
            const _SimBanner(),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: (agreed && !submitting) ? onPurchase : null,
                child: submitting
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : Text('Purchase — ${LicensingFormat.price(priceCents)}'),
              ),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _row(String label, String value, {bool muted = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: TextStyle(
                  color: muted ? AppTheme.textSecondary : AppTheme.textPrimary,
                  fontSize: 14)),
          Text(value,
              style: TextStyle(
                  color: muted ? AppTheme.textSecondary : AppTheme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  static String? _strippedHtml(String? html) {
    if (html == null) return null;
    return html.replaceAll(RegExp(r'<[^>]*>'), '').trim();
  }
}

class _SimBanner extends StatelessWidget {
  const _SimBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.secondary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.secondary.withValues(alpha: 0.3)),
      ),
      child: const Row(
        children: [
          Icon(Icons.info_outline, size: 16, color: AppTheme.secondary),
          SizedBox(width: 8),
          Expanded(
            child: Text(
              'Simulated payment — no real money is charged. Your license record '
              'is created and verifiable like a live one.',
              style: TextStyle(color: AppTheme.secondary, fontSize: 12),
            ),
          ),
        ],
      ),
    );
  }
}
