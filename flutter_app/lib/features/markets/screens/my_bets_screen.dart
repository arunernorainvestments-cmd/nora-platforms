import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:timeago/timeago.dart' as timeago;
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/n_back_button.dart';
import '../providers/markets_providers.dart';

class MyBetsScreen extends ConsumerWidget {
  const MyBetsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final betsAsync = ref.watch(myBetsProvider);

    return Scaffold(
      appBar: AppBar(
        leading: const NBackButton(fallback: '/markets'),
        title: const Text('My Bets'),
      ),
      body: betsAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off_rounded,
                  size: 48, color: AppTheme.textSecondary),
              const SizedBox(height: 16),
              const Text('Failed to load bets',
                  style: TextStyle(color: AppTheme.textSecondary)),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => ref.invalidate(myBetsProvider),
                child: const Text('Retry',
                    style: TextStyle(color: AppTheme.primary)),
              ),
            ],
          ),
        ),
        data: (bets) => RefreshIndicator(
          color: AppTheme.primary,
          backgroundColor: AppTheme.surface,
          onRefresh: () async => ref.invalidate(myBetsProvider),
          child: bets.isEmpty
              ? const CustomScrollView(
                  slivers: [
                    SliverFillRemaining(
                      child: Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.receipt_long_outlined,
                                size: 56, color: AppTheme.textSecondary),
                            SizedBox(height: 16),
                            Text(
                              'No bets yet',
                              style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: 8),
                            Text(
                              'Find a creator to bet on',
                              style: TextStyle(color: AppTheme.textSecondary),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ],
                )
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: bets.length,
                  itemBuilder: (context, i) => _BetCard(bet: bets[i]),
                ),
        ),
      ),
    );
  }
}

class _BetCard extends StatelessWidget {
  final MyBet bet;
  const _BetCard({required this.bet});

  String _statusLabel() {
    if (bet.status == 'won') return 'Won';
    if (bet.status == 'lost') return 'Lost';
    if (bet.status == 'refunded') return 'Refunded';
    final now = DateTime.now();
    if (bet.marketEndAt.isBefore(now)) return 'Pending resolution';
    return 'closes ${timeago.format(bet.marketEndAt, allowFromNow: true)}';
  }

  Color _statusColor() {
    if (bet.status == 'won') return AppTheme.success;
    if (bet.status == 'lost') return AppTheme.danger;
    if (bet.status == 'refunded') return AppTheme.textSecondary;
    return AppTheme.primary;
  }

  @override
  Widget build(BuildContext context) {
    final positionColor =
        bet.position == 'yes' ? AppTheme.success : AppTheme.danger;
    final positionLabel =
        bet.position == 'yes' ? '📈 Will Increase' : '📉 Will Decrease';
    const timeframeLabels = {
      '15m': '15 min', '1h': '1 Hour', '4h': '4 Hours', '24h': '1 Day'
    };

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '@${bet.creatorUsername}',
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _statusColor().withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border:
                      Border.all(color: _statusColor().withValues(alpha: 0.4)),
                ),
                child: Text(
                  _statusLabel(),
                  style: TextStyle(
                    color: _statusColor(),
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '${timeframeLabels[bet.timeframe] ?? bet.timeframe} market',
            style: const TextStyle(
                color: AppTheme.textSecondary, fontSize: 12),
          ),
          if (bet.identifier != null) ...[
            const SizedBox(height: 4),
            Text(
              bet.identifier!,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 10,
                letterSpacing: 0.8,
                fontFamily: 'Courier New',
              ),
            ),
          ],
          const Divider(height: 18, color: AppTheme.cardBorder),
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Position',
                        style: TextStyle(
                            color: AppTheme.textSecondary, fontSize: 11)),
                    const SizedBox(height: 2),
                    Text(
                      positionLabel,
                      style: TextStyle(
                        color: positionColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    const Text('Amount',
                        style: TextStyle(
                            color: AppTheme.textSecondary, fontSize: 11)),
                    const SizedBox(height: 2),
                    Text(
                      '${bet.amount.toStringAsFixed(0)} tokens',
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    const Text('Est. payout',
                        style: TextStyle(
                            color: AppTheme.textSecondary, fontSize: 11)),
                    const SizedBox(height: 2),
                    Text(
                      bet.potentialPayout != null
                          ? bet.potentialPayout!.toStringAsFixed(1)
                          : '—',
                      style: const TextStyle(
                        color: AppTheme.success,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
