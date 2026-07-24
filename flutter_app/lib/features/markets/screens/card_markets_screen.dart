import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/n_back_button.dart';
import '../../wallet/providers/wallet_providers.dart';
import '../providers/card_market_providers.dart';
import '../providers/markets_providers.dart'
    show MarketMakerProfile, marketMakersProvider;

/// `/markets/cards` — card-centric prediction markets (Collections spec N5).
/// Bet YES/NO in tokens on card ascension, collection sell-out, and Champion
/// Spotlight outcomes. Token-settled (Hard Rule 33). Resolution is automatic
/// from internal tables (the resolve-markets cron).
class CardMarketsScreen extends ConsumerWidget {
  const CardMarketsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final markets = ref.watch(openCardMarketsProvider);
    final balance = ref.watch(tokenBalanceProvider);
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: const NBackButton(fallback: '/markets'),
        backgroundColor: AppTheme.background,
        title: const Text('Card Markets'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: balance.maybeWhen(
                data: (b) => Text('${b.availableTokens} 🪙',
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontWeight: FontWeight.w700)),
                orElse: () => const SizedBox.shrink(),
              ),
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        backgroundColor: AppTheme.primary,
        onPressed: () => _openSpotlightMarket(context, ref),
        icon: const Icon(Icons.emoji_events_outlined),
        label: const Text('Spotlight market'),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(openCardMarketsProvider.future),
        child: markets.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(
              child: Text('Could not load: $e',
                  style: const TextStyle(color: AppTheme.danger))),
          data: (list) => list.isEmpty
              ? ListView(children: const [
                  SizedBox(height: 120),
                  Icon(Icons.insights_outlined,
                      size: 48, color: AppTheme.textSecondary),
                  SizedBox(height: 12),
                  Center(
                    child: Text('No card markets open right now',
                        style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700)),
                  ),
                  SizedBox(height: 6),
                  Padding(
                    padding: EdgeInsets.symmetric(horizontal: 40),
                    child: Text(
                      'Open one from a collection (sell-out) or a card in your '
                      'collection (ascension).',
                      textAlign: TextAlign.center,
                      style:
                          TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                    ),
                  ),
                ])
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [for (final m in list) _MarketCard(market: m)],
                ),
        ),
      ),
    );
  }

  /// The Monday that starts next week's spotlight assignment (mig 041 locks
  /// slots Monday 00:00 UTC and keys them by that date).
  static DateTime _nextMondayUtc() {
    final now = DateTime.now().toUtc();
    final today = DateTime.utc(now.year, now.month, now.day);
    return today.add(Duration(days: 8 - today.weekday));
  }

  /// Opens a "will @candidate be a Champion Spotlight next week?" token market.
  /// Candidates are the eligible Market Makers (test accounts already filtered).
  Future<void> _openSpotlightMarket(BuildContext context, WidgetRef ref) async {
    final messenger = ScaffoldMessenger.of(context);
    final week = _nextMondayUtc();
    final makers = await ref.read(marketMakersProvider.future);
    if (!context.mounted) return;
    if (makers.isEmpty) {
      messenger.showSnackBar(const SnackBar(
          content: Text('No eligible creators to predict on yet.'),
          backgroundColor: AppTheme.surface));
      return;
    }
    final picked = await showModalBottomSheet<MarketMakerProfile>(
      context: context,
      backgroundColor: AppTheme.surface,
      builder: (ctx) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'Champion Spotlight — week of ${week.month}/${week.day}',
                style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w700),
              ),
            ),
            for (final m in makers)
              ListTile(
                title: Text('@${m.username}',
                    style: const TextStyle(color: AppTheme.textPrimary)),
                subtitle: m.category1 == null
                    ? null
                    : Text(m.category1!,
                        style:
                            const TextStyle(color: AppTheme.textSecondary)),
                onTap: () => Navigator.pop(ctx, m),
              ),
          ],
        ),
      ),
    );
    if (picked == null) return;
    try {
      // Close a few hours after the Monday rollover so the assignment exists.
      await CardMarketService.createSpotlightMarket(
          candidateUserId: picked.id,
          weekStart: week,
          endAt: week.add(const Duration(hours: 6)));
      messenger.showSnackBar(SnackBar(
          content: Text('Market opened on @${picked.username}.'),
          backgroundColor: AppTheme.surface));
      ref.invalidate(openCardMarketsProvider);
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(CardMarketService.errorMessage(e)),
          backgroundColor: AppTheme.danger));
    }
  }
}

class _MarketCard extends ConsumerWidget {
  const _MarketCard({required this.market});
  final CardMarket market;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(999),
            ),
            child: Text(market.typeLabel,
                style: const TextStyle(
                    color: AppTheme.primary,
                    fontSize: 10,
                    fontWeight: FontWeight.w700)),
          ),
          const Spacer(),
          if (market.endAt != null)
            Text('closes ${_dateLabel(market.endAt!)}',
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 11)),
        ]),
        const SizedBox(height: 8),
        Text(market.title,
            style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 12),
        Row(children: [
          Expanded(
            child: _betButton(context, ref, 'yes',
                'YES · ${market.yesPool}🪙', AppTheme.success),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: _betButton(context, ref, 'no',
                'NO · ${market.noPool}🪙', AppTheme.danger),
          ),
        ]),
      ]),
    );
  }

  Widget _betButton(BuildContext context, WidgetRef ref, String position,
          String label, Color color) =>
      OutlinedButton(
        style: OutlinedButton.styleFrom(
          foregroundColor: color,
          side: BorderSide(color: color.withValues(alpha: 0.6)),
        ),
        onPressed: () => _placeBet(context, ref, position),
        child: Text(label),
      );

  Future<void> _placeBet(
      BuildContext context, WidgetRef ref, String position) async {
    final messenger = ScaffoldMessenger.of(context);
    final amountCtl = TextEditingController(text: '10');
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Bet ${position.toUpperCase()}',
            style: const TextStyle(color: AppTheme.textPrimary)),
        content: TextField(
          controller: amountCtl,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          style: const TextStyle(color: AppTheme.textPrimary),
          decoration: const InputDecoration(labelText: 'Amount (tokens)'),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Place bet')),
        ],
      ),
    );
    if (confirmed != true) return;
    final amount = int.tryParse(amountCtl.text.trim()) ?? 0;
    if (amount <= 0) return;
    try {
      await CardMarketService.placeBet(
          marketId: market.id, position: position, amount: amount);
      messenger.showSnackBar(SnackBar(
          content: Text('Bet placed: $amount tokens on ${position.toUpperCase()}.'),
          backgroundColor: AppTheme.surface));
      ref.invalidate(openCardMarketsProvider);
      ref.invalidate(tokenBalanceProvider);
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(CardMarketService.errorMessage(e)),
          backgroundColor: AppTheme.danger));
    }
  }

  static String _dateLabel(DateTime d) =>
      '${d.month}/${d.day}';
}
