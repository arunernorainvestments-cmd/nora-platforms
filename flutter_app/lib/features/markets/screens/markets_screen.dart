import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:timeago/timeago.dart' as timeago;
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/settings_menu_button.dart';
import '../../auth/providers/auth_provider.dart';
import '../providers/markets_providers.dart';

class MarketsScreen extends ConsumerStatefulWidget {
  final int initialTab;
  const MarketsScreen({super.key, this.initialTab = 0});

  @override
  ConsumerState<MarketsScreen> createState() => _MarketsScreenState();
}

class _MarketsScreenState extends ConsumerState<MarketsScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Markets'),
        actions: const [SettingsMenuButton()],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppTheme.primary,
          labelColor: AppTheme.primary,
          unselectedLabelColor: AppTheme.textSecondary,
          tabs: const [
            Tab(text: 'Open Markets'),
            Tab(text: 'My Bets'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          _OpenMarketsTab(key: PageStorageKey('open')),
          _MyBetsTab(key: PageStorageKey('myBets')),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// OPEN MARKETS TAB
// ─────────────────────────────────────────────────────────────────────────────

class _OpenMarketsTab extends ConsumerStatefulWidget {
  const _OpenMarketsTab({super.key});

  @override
  ConsumerState<_OpenMarketsTab> createState() => _OpenMarketsTabState();
}

class _OpenMarketsTabState extends ConsumerState<_OpenMarketsTab> {
  String? _selectedCategory; // null = All, 'live' = Live Now
  static const _liveKey = '__live__';

  static const _allCategories = [
    'Athlete', 'Influencer', 'Musician', 'Healthcare', 'Doctor', 'Comedian',
    'Politician', 'Gamer', 'Educator', 'Fitness', 'Business', 'Religion',
    'Researcher', 'Sports',
  ];

  Map<String, int> _categoryCounts(List<MarketListing> markets) {
    final counts = <String, int>{};
    for (final m in markets) {
      if (m.category1 != null) {
        counts[m.category1!] = (counts[m.category1!] ?? 0) + 1;
      }
      if (m.category2 != null) {
        counts[m.category2!] = (counts[m.category2!] ?? 0) + 1;
      }
    }
    return counts;
  }

  List<MarketListing> _filtered(
      List<MarketListing> markets, Set<String> liveIds) {
    if (_selectedCategory == _liveKey) {
      return markets.where((m) => liveIds.contains(m.creatorId)).toList();
    }
    if (_selectedCategory == null) return markets;
    return markets
        .where((m) =>
            m.category1 == _selectedCategory ||
            m.category2 == _selectedCategory)
        .toList();
  }

  String _emptyMessage() {
    if (_selectedCategory == _liveKey) return 'No live markets right now';
    if (_selectedCategory == null) return 'No open markets yet';
    return 'No $_selectedCategory markets';
  }

  String _emptySubtitle() {
    if (_selectedCategory == _liveKey) return 'Check back when a creator goes live';
    if (_selectedCategory == null) return 'Visit a Market Maker\'s profile to open one';
    return 'Try another category';
  }

  @override
  Widget build(BuildContext context) {
    final marketsAsync = ref.watch(openMarketsProvider);
    final liveIdsAsync = ref.watch(liveCreatorIdsProvider);
    final currentUser = ref.watch(currentUserProvider);
    final liveIds = liveIdsAsync.valueOrNull ?? {};

    return marketsAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (e, _) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off_rounded,
                size: 48, color: AppTheme.textSecondary),
            const SizedBox(height: 16),
            const Text('Failed to load markets',
                style: TextStyle(color: AppTheme.textSecondary)),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => ref.invalidate(openMarketsProvider),
              child: const Text('Retry',
                  style: TextStyle(color: AppTheme.primary)),
            ),
          ],
        ),
      ),
      data: (markets) {
        final counts = _categoryCounts(markets);
        final liveCount =
            markets.where((m) => liveIds.contains(m.creatorId)).length;
        final filtered = _filtered(markets, liveIds);

        return RefreshIndicator(
          color: AppTheme.primary,
          backgroundColor: AppTheme.surface,
          onRefresh: () async {
            ref.invalidate(openMarketsProvider);
            ref.invalidate(liveCreatorIdsProvider);
          },
          child: Column(
            children: [
              // ── Filter chips row ──────────────────────────────────────
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  children: [
                    // Live Now chip — always first
                    _FilterChip(
                      label: '🔴 Live Now',
                      count: liveCount,
                      selected: _selectedCategory == _liveKey,
                      dimmed: liveCount == 0,
                      onTap: () =>
                          setState(() => _selectedCategory = _liveKey),
                    ),
                    const SizedBox(width: 6),
                    // All chip
                    _FilterChip(
                      label: 'All',
                      count: markets.length,
                      selected: _selectedCategory == null,
                      dimmed: false,
                      onTap: () =>
                          setState(() => _selectedCategory = null),
                    ),
                    const SizedBox(width: 6),
                    // Category chips
                    ..._allCategories.map((cat) {
                      final count = counts[cat] ?? 0;
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: _FilterChip(
                          label: cat,
                          count: count,
                          selected: _selectedCategory == cat,
                          dimmed: count == 0,
                          onTap: () =>
                              setState(() => _selectedCategory = cat),
                        ),
                      );
                    }),
                  ],
                ),
              ),

              // ── Market list ───────────────────────────────────────────
              Expanded(
                child: filtered.isEmpty
                    ? CustomScrollView(
                        slivers: [
                          SliverFillRemaining(
                            child: Center(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const Icon(Icons.bar_chart_outlined,
                                      size: 56,
                                      color: AppTheme.textSecondary),
                                  const SizedBox(height: 16),
                                  Text(
                                    _emptyMessage(),
                                    style: const TextStyle(
                                      color: AppTheme.textPrimary,
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    _emptySubtitle(),
                                    style: const TextStyle(
                                        color: AppTheme.textSecondary),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
                        itemCount: filtered.length,
                        itemBuilder: (context, i) => _MarketCard(
                          market: filtered[i],
                          isLoggedIn: currentUser != null,
                          onTap: () =>
                              context.push('/markets/${filtered[i].id}'),
                        ),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final bool dimmed;
  final VoidCallback onTap;

  const _FilterChip({
    required this.label,
    required this.count,
    required this.selected,
    required this.dimmed,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.primary
              : AppTheme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: selected
                ? AppTheme.primary
                : dimmed
                    ? AppTheme.cardBorder.withValues(alpha: 0.4)
                    : AppTheme.cardBorder,
          ),
        ),
        child: Text(
          '$label ($count)',
          style: TextStyle(
            color: selected
                ? Colors.white
                : dimmed
                    ? AppTheme.textSecondary.withValues(alpha: 0.45)
                    : AppTheme.textSecondary,
            fontSize: 12,
            fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }
}

class _MarketCard extends StatelessWidget {
  final MarketListing market;
  final bool isLoggedIn;
  final VoidCallback onTap;

  const _MarketCard({
    required this.market,
    required this.isLoggedIn,
    required this.onTap,
  });

  String _timeRemaining() {
    final now = DateTime.now();
    final diff = market.endAt.difference(now);
    if (diff.isNegative) return 'Ended';
    return 'closes ${timeago.format(market.endAt, allowFromNow: true)}';
  }

  @override
  Widget build(BuildContext context) {
    final total = market.totalPool;
    final yesRatio = total > 0 ? market.yesPool / total : 0.5;
    const timeframeLabels = {'15m': '15 min', '1h': '1 Hour', '4h': '4 Hours', '24h': '1 Day'};

    return GestureDetector(
      onTap: onTap,
      child: Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Header row
            Row(
              children: [
                CircleAvatar(
                  radius: 16,
                  backgroundColor: AppTheme.primary.withValues(alpha: 0.2),
                  child: Text(
                    market.creatorUsername.isNotEmpty
                        ? market.creatorUsername[0].toUpperCase()
                        : '?',
                    style: const TextStyle(
                      color: AppTheme.primary,
                      fontSize: 13,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            '@${market.creatorUsername}',
                            style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (market.creatorTier != null) ...[
                            const SizedBox(width: 6),
                            _TierBadge(tier: market.creatorTier!),
                          ],
                        ],
                      ),
                      Text(
                        '${timeframeLabels[market.timeframe] ?? market.timeframe} · ${_timeRemaining()}',
                        style: const TextStyle(
                            color: AppTheme.textSecondary, fontSize: 12),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // Pool ratio bar
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 6,
                child: Row(
                  children: [
                    Expanded(
                      flex: (yesRatio * 100).round().clamp(1, 99),
                      child: Container(color: AppTheme.success),
                    ),
                    Expanded(
                      flex: ((1 - yesRatio) * 100).round().clamp(1, 99),
                      child: Container(color: AppTheme.danger),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),

            // Pool labels
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  '📈 ${market.yesPool.toStringAsFixed(0)}',
                  style: const TextStyle(
                      color: AppTheme.success,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
                Text(
                  '${market.totalPool.toStringAsFixed(0)} total',
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 11),
                ),
                Text(
                  '${market.noPool.toStringAsFixed(0)} 📉',
                  style: const TextStyle(
                      color: AppTheme.danger,
                      fontSize: 12,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 12),

            // View button
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: onTap,
                style: ElevatedButton.styleFrom(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  textStyle: const TextStyle(fontSize: 14),
                ),
                child: const Text('View & Bet'),
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
// MY BETS TAB
// ─────────────────────────────────────────────────────────────────────────────

class _MyBetsTab extends ConsumerWidget {
  const _MyBetsTab({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final betsAsync = ref.watch(myBetsProvider);

    return betsAsync.when(
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
                            style:
                                TextStyle(color: AppTheme.textSecondary),
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
    const timeframeLabels = {'15m': '15 min', '1h': '1 Hour', '4h': '4 Hours', '24h': '1 Day'};

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
          // Creator + timeframe
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
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _statusColor().withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: _statusColor().withValues(alpha: 0.4)),
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
          const Divider(
              height: 18, color: AppTheme.cardBorder),

          // Position + amount + payout
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

// ─────────────────────────────────────────────────────────────────────────────
// SHARED WIDGET
// ─────────────────────────────────────────────────────────────────────────────

class _TierBadge extends StatelessWidget {
  final String tier;
  const _TierBadge({required this.tier});

  static const _info = {
    'on_fire': ('🔥', 'On Fire', Color(0xFFFF6B35)),
    'rising': ('⚡', 'Rising', Color(0xFFFFD700)),
    'watched': ('👀', 'Watched', AppTheme.primary),
    'listed': ('', 'Listed', AppTheme.textSecondary),
  };

  @override
  Widget build(BuildContext context) {
    final t = _info[tier] ?? _info['listed']!;
    final color = t.$3;
    final label = '${t.$1} ${t.$2}'.trim();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
