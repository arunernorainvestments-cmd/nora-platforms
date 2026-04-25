import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/open_url.dart';
import '../providers/wallet_providers.dart';

/// Shows a modal bottom sheet with the token purchase packages.
/// Call via [showBuyTokensSheet] or use [BuyTokensSheet] directly as builder.
void showBuyTokensSheet(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => const BuyTokensSheet(),
  );
}

class BuyTokensSheet extends StatefulWidget {
  const BuyTokensSheet({super.key});

  @override
  State<BuyTokensSheet> createState() => _BuyTokensSheetState();
}

class _BuyTokensSheetState extends State<BuyTokensSheet> {
  String? _loadingId;

  Future<void> _onPackageTap(TokenPackage pkg) async {
    if (_loadingId != null) return;
    setState(() => _loadingId = pkg.id);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'create-checkout-session',
        body: {'package_id': pkg.id},
      );
      final sessionUrl = res.data['session_url'] as String?;
      if (sessionUrl != null && mounted) {
        await openUrlInBrowser(sessionUrl);
        if (mounted) Navigator.of(context).pop();
      }
    } catch (_) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: const Text('Failed to start checkout. Please try again.'),
            backgroundColor: AppTheme.surface,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: const BorderSide(color: AppTheme.cardBorder),
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingId = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.cardBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Text(
              'Buy Tokens',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Tokens fuel promotions, bets, and power-ups.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 20),
            ...kTokenPackages.map((pkg) => _PackageCard(
                  pkg: pkg,
                  isLoading: _loadingId == pkg.id,
                  disabled: _loadingId != null && _loadingId != pkg.id,
                  onTap: () => _onPackageTap(pkg),
                )),
          ],
        ),
      ),
    );
  }
}

class _PackageCard extends StatelessWidget {
  final TokenPackage pkg;
  final bool isLoading;
  final bool disabled;
  final VoidCallback onTap;

  const _PackageCard({
    required this.pkg,
    required this.isLoading,
    required this.disabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isPopular = pkg.badge == 'Most Popular';

    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: disabled || isLoading ? null : onTap,
          borderRadius: BorderRadius.circular(14),
          child: Opacity(
            opacity: disabled ? 0.45 : 1.0,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
              decoration: BoxDecoration(
                color: AppTheme.surfaceLight,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: isPopular ? AppTheme.primary : AppTheme.cardBorder,
                  width: isPopular ? 1.5 : 1,
                ),
              ),
              child: Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      color: AppTheme.surface,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Center(
                      child: Text('🪙', style: TextStyle(fontSize: 20)),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Text(
                              pkg.label,
                              style: const TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            if (pkg.badge != null) ...[
                              const SizedBox(width: 8),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 7, vertical: 2),
                                decoration: BoxDecoration(
                                  color: isPopular
                                      ? AppTheme.primary.withValues(alpha: 0.2)
                                      : AppTheme.secondary
                                          .withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                ),
                                child: Text(
                                  pkg.badge!,
                                  style: TextStyle(
                                    color: isPopular
                                        ? AppTheme.primary
                                        : AppTheme.secondary,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          '${pkg.tokens} tokens',
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isLoading)
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: AppTheme.primary,
                      ),
                    )
                  else
                    Text(
                      pkg.priceDisplay,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
