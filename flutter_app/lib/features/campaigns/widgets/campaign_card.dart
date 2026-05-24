import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/campaigns_providers.dart';

class CampaignCard extends StatelessWidget {
  final Campaign campaign;
  final VoidCallback onTap;

  const CampaignCard({super.key, required this.campaign, required this.onTap});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.compactCurrency(symbol: '\$', decimalDigits: 0);
    final pct = campaign.fundingProgressPct;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(
              child: Text(campaign.title,
                  style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis),
            ),
            const SizedBox(width: 8),
            _CategoryBadge(campaign.category),
          ]),
          const SizedBox(height: 4),
          Text('@${campaign.creatorUsername}',
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 12)),
          const SizedBox(height: 12),
          LinearProgressIndicator(
            value: pct,
            backgroundColor: AppTheme.cardBorder,
            valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.primary),
            minHeight: 4,
            borderRadius: BorderRadius.circular(2),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${fmt.format(campaign.currentFundingUsdCents / 100)} raised',
                style: const TextStyle(
                    color: AppTheme.textPrimary, fontSize: 13),
              ),
              Text(
                '${(pct * 100).toStringAsFixed(0)}% of ${fmt.format(campaign.fundingGoalUsdCents / 100)}',
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 12),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(children: [
            const Icon(Icons.pie_chart_outline,
                size: 13, color: AppTheme.secondary),
            const SizedBox(width: 4),
            Text(
              '${campaign.royaltyPctOffered.toStringAsFixed(1)}% royalty · '
              '${campaign.royaltyTermYears != null ? "${campaign.royaltyTermYears}yr" : "perpetual"}',
              style: const TextStyle(
                  color: AppTheme.secondary, fontSize: 12),
            ),
            if (campaign.isSimulated) ...[
              const SizedBox(width: 8),
              const Text('SIM',
                  style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 10,
                      letterSpacing: 0.8)),
            ],
          ]),
        ]),
      ),
    );
  }
}

class _CategoryBadge extends StatelessWidget {
  final String category;
  const _CategoryBadge(this.category);

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: AppTheme.primary.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Text(
          category,
          style: const TextStyle(
              color: AppTheme.primary, fontSize: 11, fontWeight: FontWeight.w600),
        ),
      );
}
