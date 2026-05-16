import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/n_glass_sheet.dart';
import '../providers/promotion_providers.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────

void showPromotionsSheet(BuildContext context, {required String targetUserId}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _PromotionsSheet(targetUserId: targetUserId),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Sheet
// ─────────────────────────────────────────────────────────────────────────────

class _PromotionsSheet extends ConsumerStatefulWidget {
  final String targetUserId;
  const _PromotionsSheet({required this.targetUserId});

  @override
  ConsumerState<_PromotionsSheet> createState() => _PromotionsSheetState();
}

class _PromotionsSheetState extends ConsumerState<_PromotionsSheet> {
  String? _loadingType;

  Future<void> _apply(String boostType) async {
    if (_loadingType != null) return;
    setState(() => _loadingType = boostType);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'apply-promotion',
        body: {
          'boost_type': boostType,
          'target_user_id': widget.targetUserId,
        },
      );
      if (res.data?['error'] != null) {
        throw Exception(res.data['error'] as String);
      }
      if (mounted) {
        Navigator.of(context).pop();
        messenger.showSnackBar(
          SnackBar(
            content: Text(_successMessage(boostType)),
            backgroundColor: AppTheme.success,
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
            backgroundColor: AppTheme.danger,
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingType = null);
    }
  }

  String _successMessage(String type) => switch (type) {
        'quick_boost' => 'Quick Boost applied! Heat Score rising.',
        'major_boost' => 'Major Boost applied! Heat Score rising.',
        'spotlight_entry' => 'Spotlight Entry active for 4 hours!',
        _ => 'Promotion applied!',
      };

  @override
  Widget build(BuildContext context) {
    final contextAsync = ref.watch(promotionContextProvider);

    return NGlassSheet(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const NSheetHandle(),
              const SizedBox(height: 20),

              // Title
              const Text(
              'Promote Yourself',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Boost your Heat Score to climb the spotlight.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 16),

            contextAsync.when(
              loading: () => const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(color: AppTheme.primary),
                ),
              ),
              error: (_, __) => const _ErrorState(),
              data: (ctx) => Column(
                children: [
                  // Discount / multiplier banners
                  if (ctx.hasMarketMakerDiscount) ...[
                    const _BannerChip(
                      icon: '🎟️',
                      label: '20% Market Maker discount active',
                      color: AppTheme.success,
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (ctx.hasActiveBetMultiplier) ...[
                    const _BannerChip(
                      icon: '⚡',
                      label: '1.5× heat multiplier — your market has ≥200 tokens bet',
                      color: AppTheme.secondary,
                    ),
                    const SizedBox(height: 8),
                  ],
                  if (ctx.hasMarketMakerDiscount || ctx.hasActiveBetMultiplier)
                    const SizedBox(height: 8),

                  _PromoCard(
                    emoji: '⚡',
                    title: 'Quick Boost',
                    subtitle: '+${effectiveDelta(8, hasMultiplier: ctx.hasActiveBetMultiplier)} Heat Score for 1 hour',
                    cost: effectiveCost(80, hasMakerDiscount: ctx.hasMarketMakerDiscount),
                    originalCost: ctx.hasMarketMakerDiscount ? 80 : null,
                    isLoading: _loadingType == 'quick_boost',
                    disabled: _loadingType != null && _loadingType != 'quick_boost',
                    onTap: () => _apply('quick_boost'),
                  ),
                  const SizedBox(height: 12),

                  _PromoCard(
                    emoji: '🚀',
                    title: 'Major Boost',
                    subtitle: '+${effectiveDelta(20, hasMultiplier: ctx.hasActiveBetMultiplier)} Heat Score for 1 hour',
                    cost: effectiveCost(250, hasMakerDiscount: ctx.hasMarketMakerDiscount),
                    originalCost: ctx.hasMarketMakerDiscount ? 250 : null,
                    isLoading: _loadingType == 'major_boost',
                    disabled: _loadingType != null && _loadingType != 'major_boost',
                    onTap: () => _apply('major_boost'),
                  ),
                  const SizedBox(height: 12),

                  _PromoCard(
                    emoji: '✨',
                    title: 'Spotlight Entry',
                    subtitle: 'Guaranteed Spotlight slot for 4 hours',
                    cost: effectiveCost(500, hasMakerDiscount: ctx.hasMarketMakerDiscount),
                    originalCost: ctx.hasMarketMakerDiscount ? 500 : null,
                    isLoading: _loadingType == 'spotlight_entry',
                    disabled: _loadingType != null && _loadingType != 'spotlight_entry',
                    onTap: () => _apply('spotlight_entry'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Promo card
// ─────────────────────────────────────────────────────────────────────────────

class _PromoCard extends StatelessWidget {
  final String emoji;
  final String title;
  final String subtitle;
  final int cost;
  final int? originalCost;
  final bool isLoading;
  final bool disabled;
  final VoidCallback onTap;

  const _PromoCard({
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.cost,
    this.originalCost,
    required this.isLoading,
    required this.disabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: disabled ? 0.45 : 1.0,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: disabled || isLoading ? null : onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 16),
            decoration: BoxDecoration(
              color: AppTheme.surfaceLight,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.cardBorder),
            ),
            child: Row(
              children: [
                // Icon
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppTheme.surface,
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child: Text(emoji, style: const TextStyle(fontSize: 20)),
                  ),
                ),
                const SizedBox(width: 14),

                // Text
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),

                // Cost / spinner
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
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        '$cost 🪙',
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      if (originalCost != null)
                        Text(
                          '$originalCost 🪙',
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 12,
                            decoration: TextDecoration.lineThrough,
                          ),
                        ),
                    ],
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _BannerChip extends StatelessWidget {
  final String icon;
  final String label;
  final Color color;

  const _BannerChip({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.3)),
      ),
      child: Row(
        children: [
          Text(icon, style: const TextStyle(fontSize: 14)),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  const _ErrorState();

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 32),
      child: Center(
        child: Text(
          'Could not load promotion details.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
      ),
    );
  }
}
