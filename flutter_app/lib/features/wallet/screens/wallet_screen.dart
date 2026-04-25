import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shimmer/shimmer.dart';
import 'package:timeago/timeago.dart' as timeago;
import '../../../core/theme/app_theme.dart';
import '../providers/wallet_providers.dart';
import '../widgets/buy_tokens_sheet.dart';
import '../../../core/widgets/settings_menu_button.dart';

class WalletScreen extends ConsumerStatefulWidget {
  final String? purchaseResult;
  const WalletScreen({super.key, this.purchaseResult});

  @override
  ConsumerState<WalletScreen> createState() => _WalletScreenState();
}

class _WalletScreenState extends ConsumerState<WalletScreen> {
  @override
  void initState() {
    super.initState();
    if (widget.purchaseResult == 'success') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.invalidate(tokenBalanceProvider);
        ref.invalidate(tokenTransactionsProvider);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Tokens added to your balance!'),
            backgroundColor: AppTheme.success,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      });
    } else if (widget.purchaseResult == 'cancelled') {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Purchase cancelled.'),
            backgroundColor: AppTheme.surface,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: const BorderSide(color: AppTheme.cardBorder),
            ),
          ),
        );
      });
    }
  }

  void _showBuyTokensSheet() => showBuyTokensSheet(context);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Wallet'),
        actions: const [SettingsMenuButton()],
      ),
      body: RefreshIndicator(
        color: AppTheme.primary,
        backgroundColor: AppTheme.surface,
        onRefresh: () async {
          ref.invalidate(tokenBalanceProvider);
          ref.invalidate(tokenTransactionsProvider);
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
          children: [
            _TokenBalanceSection(onGetMoreTokens: _showBuyTokensSheet),
            const SizedBox(height: 28),
            const _TokenActivitySection(),
            const SizedBox(height: 28),
            const _CashBalanceSection(),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SECTION 1 — TOKEN BALANCE CARD
// ─────────────────────────────────────────────────────────────────────────────

class _TokenBalanceSection extends ConsumerWidget {
  final VoidCallback onGetMoreTokens;
  const _TokenBalanceSection({required this.onGetMoreTokens});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balanceAsync = ref.watch(tokenBalanceProvider);
    return balanceAsync.when(
      loading: () => const _BalanceShimmer(),
      error: (_, __) => _SectionErrorState(
        onRetry: () => ref.invalidate(tokenBalanceProvider),
      ),
      data: (balance) => _TokenBalanceCard(
        balance: balance,
        onGetMoreTokens: onGetMoreTokens,
      ),
    );
  }
}

class _TokenBalanceCard extends StatelessWidget {
  final TokenBalance balance;
  final VoidCallback onGetMoreTokens;
  const _TokenBalanceCard({required this.balance, required this.onGetMoreTokens});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [AppTheme.primary, Color(0xFF9C27B0)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Row(
            children: [
              const Text('🪙', style: TextStyle(fontSize: 20)),
              const SizedBox(width: 8),
              Text(
                'Token Balance',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                  letterSpacing: 0.3,
                ),
              ),
            ],
          ),

          const SizedBox(height: 12),

          // Large token count
          Text(
            '${balance.availableTokens}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 52,
              fontWeight: FontWeight.bold,
              height: 1.0,
              letterSpacing: -1,
            ),
          ),
          const Text(
            'tokens available',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),

          const SizedBox(height: 20),

          // Lifetime stats row
          Row(
            children: [
              _LifetimeStat(label: 'Lifetime Earned', value: '${balance.lifetimeEarned}'),
              const SizedBox(width: 12),
              _LifetimeStat(label: 'Lifetime Spent', value: '${balance.lifetimeSpent}'),
            ],
          ),

          const SizedBox(height: 20),

          // Get More Tokens button
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: onGetMoreTokens,
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: const BorderSide(color: Colors.white54, width: 1.5),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
              child: const Text('Get More Tokens'),
            ),
          ),
        ],
      ),
    );
  }
}

class _LifetimeStat extends StatelessWidget {
  final String label;
  final String value;
  const _LifetimeStat({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 11,
                letterSpacing: 0.2,
              ),
            ),
            const SizedBox(height: 3),
            Text(
              value,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SECTION 2 — RECENT TOKEN ACTIVITY
// ─────────────────────────────────────────────────────────────────────────────

class _TokenActivitySection extends ConsumerWidget {
  const _TokenActivitySection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final txAsync = ref.watch(tokenTransactionsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: 'Recent Activity'),
        const SizedBox(height: 12),
        txAsync.when(
          loading: () => const _ActivityShimmer(),
          error: (_, __) => _SectionErrorState(
            onRetry: () => ref.invalidate(tokenTransactionsProvider),
          ),
          data: (transactions) {
            if (transactions.isEmpty) return const _EmptyActivity();
            return Container(
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.cardBorder),
              ),
              child: ListView.separated(
                shrinkWrap: true,
                physics: const NeverScrollableScrollPhysics(),
                itemCount: transactions.length,
                separatorBuilder: (_, __) => const Divider(
                  height: 1,
                  color: AppTheme.cardBorder,
                  indent: 16,
                  endIndent: 16,
                ),
                itemBuilder: (context, i) => _TransactionRow(tx: transactions[i]),
              ),
            );
          },
        ),
      ],
    );
  }
}

class _TransactionRow extends StatelessWidget {
  final TokenTransaction tx;
  const _TransactionRow({required this.tx});

  @override
  Widget build(BuildContext context) {
    final isCredit = tx.isCredit;
    final amountColor = isCredit ? AppTheme.success : AppTheme.danger;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      child: Row(
        children: [
          // Type icon
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppTheme.surfaceLight,
              borderRadius: BorderRadius.circular(10),
            ),
            child: Center(
              child: Text(tx.typeIcon, style: const TextStyle(fontSize: 18)),
            ),
          ),
          const SizedBox(width: 12),

          // Description + timestamp
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tx.description ?? tx.typeLabel,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  timeago.format(tx.createdAt),
                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),

          // Amount
          Text(
            tx.amountDisplay,
            style: TextStyle(
              color: amountColor,
              fontSize: 15,
              fontWeight: FontWeight.bold,
            ),
          ),
        ],
      ),
    );
  }
}

class _EmptyActivity extends StatelessWidget {
  const _EmptyActivity();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 36),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: const Column(
        children: [
          Text('🪙', style: TextStyle(fontSize: 32)),
          SizedBox(height: 12),
          Text(
            'No token activity yet',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SECTION 3 — CASH BALANCE (PLACEHOLDER)
// ─────────────────────────────────────────────────────────────────────────────

class _CashBalanceSection extends StatelessWidget {
  const _CashBalanceSection();

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(title: 'Cash Balance'),
        const SizedBox(height: 12),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.cardBorder),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppTheme.surfaceLight,
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(
                  Icons.account_balance_wallet_outlined,
                  color: AppTheme.textSecondary,
                  size: 22,
                ),
              ),
              const SizedBox(width: 14),
              const Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      r'$0.00',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'Deposits and withdrawals coming in Phase 4',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHARED WIDGETS
// ─────────────────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader({required this.title});

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: const TextStyle(
        color: AppTheme.textPrimary,
        fontSize: 16,
        fontWeight: FontWeight.bold,
      ),
    );
  }
}

class _SectionErrorState extends StatelessWidget {
  final VoidCallback onRetry;
  const _SectionErrorState({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 24),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        children: [
          const Text(
            'Could not load data',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
          ),
          const SizedBox(height: 10),
          TextButton(
            onPressed: onRetry,
            child: const Text(
              'Retry',
              style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHIMMER STATES
// ─────────────────────────────────────────────────────────────────────────────

class _BalanceShimmer extends StatelessWidget {
  const _BalanceShimmer();

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AppTheme.surface,
      highlightColor: AppTheme.cardBorder,
      child: Container(
        height: 240,
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(20),
        ),
      ),
    );
  }
}

class _ActivityShimmer extends StatelessWidget {
  const _ActivityShimmer();

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AppTheme.surface,
      highlightColor: AppTheme.cardBorder,
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(16),
        ),
        child: Column(
          children: List.generate(
            4,
            (i) => Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
              child: Row(
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      color: AppTheme.cardBorder,
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Container(
                          height: 13,
                          width: double.infinity,
                          decoration: BoxDecoration(
                            color: AppTheme.cardBorder,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          height: 11,
                          width: 80,
                          decoration: BoxDecoration(
                            color: AppTheme.cardBorder,
                            borderRadius: BorderRadius.circular(4),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Container(
                    height: 15,
                    width: 36,
                    decoration: BoxDecoration(
                      color: AppTheme.cardBorder,
                      borderRadius: BorderRadius.circular(4),
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
