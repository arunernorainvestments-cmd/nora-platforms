import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/campaigns_providers.dart';
import '../widgets/invest_bottom_sheet.dart';

class CampaignDetailScreen extends ConsumerWidget {
  final String campaignId;
  const CampaignDetailScreen({super.key, required this.campaignId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final campaign = ref.watch(campaignDetailProvider(campaignId));

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: campaign.maybeWhen(
          data: (c) => Text(c.title, overflow: TextOverflow.ellipsis),
          orElse: () => const Text('Campaign'),
        ),
      ),
      body: campaign.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => const Center(
          child: Text('Campaign not found',
              style: TextStyle(color: AppTheme.textSecondary)),
        ),
        data: (c) => _CampaignBody(campaign: c),
      ),
    );
  }
}

class _CampaignBody extends ConsumerWidget {
  final Campaign campaign;
  const _CampaignBody({required this.campaign});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fmt = NumberFormat.currency(symbol: '\$', decimalDigits: 0);
    final pct = campaign.fundingProgressPct;
    final daysLeft = campaign.closesAt?.difference(DateTime.now()).inDays;
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    final isCreator = currentUserId == campaign.creatorId;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Cover image
          if (campaign.coverImageUrl != null)
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.network(
                campaign.coverImageUrl!,
                height: 200,
                width: double.infinity,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => const SizedBox.shrink(),
              ),
            ),
          if (campaign.coverImageUrl != null) const SizedBox(height: 20),

          // Title + creator
          Text(campaign.title,
              style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text('by @${campaign.creatorUsername}',
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
          const SizedBox(height: 16),

          // Mode badge
          if (campaign.isSimulated)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
              decoration: BoxDecoration(
                color: AppTheme.secondary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(color: AppTheme.secondary.withValues(alpha: 0.4)),
              ),
              child: const Text('SIMULATION',
                  style: TextStyle(
                      color: AppTheme.secondary,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 1)),
            ),
          const SizedBox(height: 20),

          // Funding progress
          _InfoCard(children: [
            _ProgressRow(
              raised: campaign.currentFundingUsdCents,
              goal: campaign.fundingGoalUsdCents,
              pct: pct,
              fmt: fmt,
            ),
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: pct,
              backgroundColor: AppTheme.cardBorder,
              valueColor:
                  const AlwaysStoppedAnimation<Color>(AppTheme.primary),
              minHeight: 6,
              borderRadius: BorderRadius.circular(3),
            ),
            const SizedBox(height: 12),
            Row(children: [
              _Stat(
                label: 'Royalty offered',
                value: '${campaign.royaltyPctOffered.toStringAsFixed(1)}%',
              ),
              const SizedBox(width: 24),
              _Stat(
                label: 'Term',
                value: campaign.royaltyTermYears != null
                    ? '${campaign.royaltyTermYears}yr'
                    : 'Perpetual',
              ),
              if (daysLeft != null) ...[
                const SizedBox(width: 24),
                _Stat(
                  label: 'Days left',
                  value: daysLeft > 0 ? '$daysLeft' : 'Ended',
                  valueColor: daysLeft <= 3 ? AppTheme.danger : null,
                ),
              ],
            ]),
          ]),
          const SizedBox(height: 16),

          // Description
          if (campaign.description != null && campaign.description!.isNotEmpty) ...[
            const Text('About',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(campaign.description!,
                style: const TextStyle(
                    color: AppTheme.textSecondary, height: 1.6)),
            const SizedBox(height: 24),
          ],

          // Invest button
          if (campaign.status == CampaignStatus.open)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => _showInvestSheet(context, ref),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(
                  campaign.isSimulated ? 'Invest (Simulated)' : 'Invest',
                  style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ),

          if (campaign.status == CampaignStatus.funded)
            const _StatusBanner(
              message: 'Funded! Creator is delivering the work.',
              color: AppTheme.success,
            ),
          if (campaign.status == CampaignStatus.active)
            const _StatusBanner(
              message: 'Active — royalties are flowing.',
              color: AppTheme.secondary,
            ),
          if (campaign.status == CampaignStatus.failed)
            const _StatusBanner(
              message: 'This campaign did not reach its goal. Investments were refunded.',
              color: AppTheme.danger,
            ),

          const SizedBox(height: 16),

          // Creator: report revenue (funded or active)
          if (isCreator &&
              (campaign.status == CampaignStatus.funded ||
                  campaign.status == CampaignStatus.active))
            OutlinedButton.icon(
              onPressed: () => context.push(
                '/campaign/${campaign.id}/revenue',
                extra: campaign,
              ),
              icon: const Icon(Icons.attach_money, size: 18),
              label: const Text('Report Revenue'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.secondary,
                side: const BorderSide(color: AppTheme.secondary),
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),

          // Backer: view earnings
          if (!isCreator && currentUserId != null &&
              campaign.status == CampaignStatus.active) ...[
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => context.push('/campaigns/earnings'),
              icon: const Icon(Icons.account_balance_wallet_outlined, size: 18),
              label: const Text('My Earnings'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.primary,
                side: const BorderSide(color: AppTheme.primary),
                minimumSize: const Size(double.infinity, 48),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],

          // Governance + updates (funded or active)
          if (campaign.status == CampaignStatus.funded ||
              campaign.status == CampaignStatus.active) ...[
            const SizedBox(height: 16),
            const Divider(color: AppTheme.cardBorder, height: 1),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => context.push(
                    '/campaign/${campaign.id}/proposals',
                    extra: {
                      'isCreator': isCreator,
                      'escrowBalanceCents': campaign.escrowBalanceCents,
                    },
                  ),
                  icon: const Icon(Icons.how_to_vote_outlined, size: 16),
                  label: const Text('Proposals'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.secondary,
                    side: const BorderSide(color: AppTheme.secondary),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => context.push(
                    '/campaign/${campaign.id}/updates',
                    extra: isCreator,
                  ),
                  icon: const Icon(Icons.campaign_outlined, size: 16),
                  label: const Text('Updates'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.textSecondary,
                    side: const BorderSide(color: AppTheme.cardBorder),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                ),
              ),
            ]),
          ],

          const SizedBox(height: 40),
        ],
      ),
    );
  }

  void _showInvestSheet(BuildContext context, WidgetRef ref) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => InvestBottomSheet(campaign: campaign, ref: ref),
    );
  }
}

class _InfoCard extends StatelessWidget {
  final List<Widget> children;
  const _InfoCard({required this.children});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );
}

class _ProgressRow extends StatelessWidget {
  final int raised;
  final int goal;
  final double pct;
  final NumberFormat fmt;
  const _ProgressRow(
      {required this.raised,
      required this.goal,
      required this.pct,
      required this.fmt});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(fmt.format(raised / 100),
                style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.bold)),
            const Text('raised',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
          ]),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(fmt.format(goal / 100),
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 16)),
            const Text('goal',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
          ]),
        ],
      );
}

class _Stat extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;
  const _Stat({required this.label, required this.value, this.valueColor});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(value,
              style: TextStyle(
                  color: valueColor ?? AppTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600)),
          Text(label,
              style:
                  const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
        ],
      );
}

class _StatusBanner extends StatelessWidget {
  final String message;
  final Color color;
  const _StatusBanner({required this.message, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: color.withValues(alpha: 0.35)),
        ),
        child:
            Text(message, style: TextStyle(color: color, fontSize: 14)),
      );
}
