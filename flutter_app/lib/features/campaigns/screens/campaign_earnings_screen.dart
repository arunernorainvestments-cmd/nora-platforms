import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/campaigns_providers.dart';

class CampaignEarningsScreen extends ConsumerWidget {
  const CampaignEarningsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final distributions = ref.watch(myDistributionsProvider);
    final simBalance = ref.watch(simBalanceProvider);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: const Text('My Earnings'),
      ),
      body: distributions.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => const Center(
          child: Text('Failed to load earnings',
              style: TextStyle(color: AppTheme.textSecondary)),
        ),
        data: (list) => _EarningsBody(distributions: list, simBalance: simBalance),
      ),
    );
  }
}

class _EarningsBody extends StatelessWidget {
  final List<Distribution> distributions;
  final AsyncValue<SimBalance?> simBalance;

  const _EarningsBody({required this.distributions, required this.simBalance});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
    final dateFmt = DateFormat('MMM d, yyyy');

    final totalEarned = distributions
        .where((d) => d.status == 'completed')
        .fold<int>(0, (sum, d) => sum + d.netCents);

    final pending = distributions
        .where((d) => d.status == 'queued' || d.status == 'processing')
        .fold<int>(0, (sum, d) => sum + d.netCents);

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // Summary cards
        Row(children: [
          Expanded(
            child: _SummaryCard(
              label: 'Total earned',
              value: fmt.format(totalEarned / 100),
              color: AppTheme.success,
              icon: Icons.trending_up,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: _SummaryCard(
              label: 'Pending',
              value: fmt.format(pending / 100),
              color: AppTheme.secondary,
              icon: Icons.hourglass_top_outlined,
            ),
          ),
        ]),

        // Sim balance row
        simBalance.when(
          loading: () => const SizedBox.shrink(),
          error: (_, __) => const SizedBox.shrink(),
          data: (b) {
            if (b == null) return const SizedBox.shrink();
            return Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.cardBorder),
                ),
                child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Sim wallet balance',
                          style: TextStyle(color: AppTheme.textSecondary)),
                      Text(fmt.format(b.balanceUsdCents / 100),
                          style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontWeight: FontWeight.w600)),
                    ]),
              ),
            );
          },
        ),

        const SizedBox(height: 24),

        if (distributions.isEmpty)
          const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(vertical: 40),
              child: Text(
                'No earnings yet.\nBack a campaign to start earning royalties.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textSecondary, height: 1.6),
              ),
            ),
          )
        else ...[
          const Text('Distribution history',
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          ...distributions.map((d) => _DistributionRow(
                distribution: d,
                fmt: fmt,
                dateFmt: dateFmt,
              )),
        ],
      ],
    );
  }
}

class _SummaryCard extends StatelessWidget {
  final String label;
  final String value;
  final Color color;
  final IconData icon;

  const _SummaryCard({
    required this.label,
    required this.value,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Icon(icon, size: 18, color: color),
          const SizedBox(height: 8),
          Text(value,
              style: TextStyle(
                  color: color, fontSize: 18, fontWeight: FontWeight.bold)),
          Text(label,
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 12)),
        ]),
      );
}

class _DistributionRow extends StatelessWidget {
  final Distribution distribution;
  final NumberFormat fmt;
  final DateFormat dateFmt;

  const _DistributionRow({
    required this.distribution,
    required this.fmt,
    required this.dateFmt,
  });

  Color get _statusColor {
    switch (distribution.status) {
      case 'completed':
        return AppTheme.success;
      case 'queued':
      case 'processing':
        return AppTheme.secondary;
      case 'failed':
        return AppTheme.danger;
      default:
        return AppTheme.textSecondary;
    }
  }

  @override
  Widget build(BuildContext context) => Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Row(children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: _statusColor.withValues(alpha: 0.15),
              shape: BoxShape.circle,
            ),
            child: Icon(
              distribution.status == 'completed'
                  ? Icons.check
                  : distribution.status == 'failed'
                      ? Icons.close
                      : Icons.schedule,
              size: 16,
              color: _statusColor,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${distribution.royaltyPctAtTime.toStringAsFixed(4)}% royalty',
                  style: const TextStyle(
                      color: AppTheme.textPrimary, fontSize: 13),
                ),
                if (distribution.distributedAt != null)
                  Text(
                    dateFmt.format(distribution.distributedAt!),
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 11),
                  ),
              ],
            ),
          ),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(
              fmt.format(distribution.netCents / 100),
              style: TextStyle(
                  color: _statusColor,
                  fontSize: 15,
                  fontWeight: FontWeight.bold),
            ),
            if (distribution.isSimulated)
              const Text('sim',
                  style: TextStyle(
                      color: AppTheme.textSecondary, fontSize: 10)),
          ]),
        ]),
      );
}
