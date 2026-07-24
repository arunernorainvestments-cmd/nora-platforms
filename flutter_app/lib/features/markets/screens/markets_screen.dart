import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/constants/creator_categories.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/n_tappable.dart';
import '../../../core/widgets/settings_menu_button.dart';
import '../providers/markets_providers.dart';
import '../widgets/battle_bet_sheet.dart';

// ─────────────────────────────────────────────────────────────────────────────
// SCREEN
// ─────────────────────────────────────────────────────────────────────────────

class MarketsScreen extends ConsumerWidget {
  const MarketsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Markets'),
        actions: [
          // Card-centric markets (Collections spec N5) — ascension, sell-out,
          // spotlight. Same token rail, different subjects.
          IconButton(
            tooltip: 'Card Markets',
            icon: const Icon(Icons.insights_outlined),
            onPressed: () => context.go('/markets/cards'),
          ),
          const SettingsMenuButton(),
        ],
      ),
      body: const _MarketsBody(key: PageStorageKey('markets')),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BODY
// ─────────────────────────────────────────────────────────────────────────────

class _MarketsBody extends ConsumerStatefulWidget {
  const _MarketsBody({super.key});

  @override
  ConsumerState<_MarketsBody> createState() => _MarketsBodyState();
}

class _MarketsBodyState extends ConsumerState<_MarketsBody> {
  String? _selectedCategory; // null = All, '__live__' = Live Now, else primary
  static const _liveKey = '__live__';

  @override
  Widget build(BuildContext context) {
    final makersAsync = ref.watch(marketMakersProvider);

    return makersAsync.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, __) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off_rounded,
                size: 48, color: AppTheme.textSecondary),
            const SizedBox(height: 16),
            const Text('Failed to load',
                style: TextStyle(color: AppTheme.textSecondary)),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => ref.invalidate(marketMakersProvider),
              child: const Text('Retry',
                  style: TextStyle(color: AppTheme.primary)),
            ),
          ],
        ),
      ),
      data: (makers) {
        final liveCount = makers.where((m) => m.isLive).length;
        final counts = _categoryCounts(makers);

        return RefreshIndicator(
          color: AppTheme.primary,
          backgroundColor: AppTheme.surface,
          onRefresh: () async => ref.invalidate(marketMakersProvider),
          child: Column(
            children: [
              // ── Filter tabs ──────────────────────────────────────────────
              SizedBox(
                height: 48,
                child: ListView(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  children: [
                    _FilterChip(
                      label: '🔴 Live Now',
                      count: liveCount,
                      selected: _selectedCategory == _liveKey,
                      dimmed: liveCount == 0,
                      onTap: () =>
                          setState(() => _selectedCategory = _liveKey),
                    ),
                    const SizedBox(width: 6),
                    _FilterChip(
                      label: 'All',
                      count: makers.length,
                      selected: _selectedCategory == null,
                      dimmed: false,
                      onTap: () => setState(() => _selectedCategory = null),
                    ),
                    const SizedBox(width: 6),
                    ...kPrimaryCategories.map((cat) {
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

              // ── Content ──────────────────────────────────────────────────
              Expanded(
                child: _selectedCategory == _liveKey
                    ? _LiveNowContent(makers: makers)
                    : _CategoryContent(
                        makers: makers,
                        primaryFilter: _selectedCategory,
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Map<String, int> _categoryCounts(List<MarketMakerProfile> makers) {
    final counts = <String, int>{};
    for (final m in makers) {
      if (m.category1 != null) {
        counts[m.category1!] = (counts[m.category1!] ?? 0) + 1;
      }
    }
    return counts;
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// LIVE NOW CONTENT — single horizontal row, no subcategory grouping
// ─────────────────────────────────────────────────────────────────────────────

class _LiveNowContent extends StatelessWidget {
  final List<MarketMakerProfile> makers;
  const _LiveNowContent({required this.makers});

  @override
  Widget build(BuildContext context) {
    final live = makers.where((m) => m.isLive).toList();

    if (live.isEmpty) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.live_tv_outlined,
                size: 48, color: AppTheme.textSecondary),
            SizedBox(height: 16),
            Text(
              'No creators are live right now',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            SizedBox(height: 6),
            Text(
              'Check back when a creator goes live',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return CustomScrollView(
      slivers: [
        const SliverToBoxAdapter(
          child: Padding(
            padding: EdgeInsets.fromLTRB(16, 20, 16, 8),
            child: Text(
              '🔴 Live Now — Creators streaming right now',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: _HorizontalCreatorRow(makers: live),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 32)),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CATEGORY CONTENT — subcategory sections with horizontal scroll per section
// ─────────────────────────────────────────────────────────────────────────────

class _CategoryContent extends StatelessWidget {
  final List<MarketMakerProfile> makers;
  final String? primaryFilter; // null = All

  const _CategoryContent({
    required this.makers,
    this.primaryFilter,
  });

  @override
  Widget build(BuildContext context) {
    final sections = _buildSections(makers, primaryFilter);

    if (sections.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.bar_chart_outlined,
                size: 56, color: AppTheme.textSecondary),
            const SizedBox(height: 16),
            Text(
              primaryFilter != null
                  ? 'No $primaryFilter Market Makers yet'
                  : 'No Market Makers yet',
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Visit a creator\'s profile to open a market',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
          ],
        ),
      );
    }

    return CustomScrollView(
      slivers: [
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
        // Live battle markets (renders nothing until a battle starts one).
        if (primaryFilter == null)
          const SliverToBoxAdapter(child: _BattleMarketsSection()),
        for (final section in sections) ...[
          SliverToBoxAdapter(
            child: _SectionHeader(
              primary: section.primary,
              subcategory: section.subcategory,
              showPrimary: primaryFilter == null,
            ),
          ),
          SliverToBoxAdapter(
            child: _HorizontalCreatorRow(makers: section.makers),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 32)),
        ],
      ],
    );
  }

  List<_CategorySection> _buildSections(
      List<MarketMakerProfile> all, String? primaryFilter) {
    final sections = <_CategorySection>[];
    final primaries =
        primaryFilter != null ? [primaryFilter] : kPrimaryCategories;

    for (final primary in primaries) {
      final byPrimary =
          all.where((m) => m.category1 == primary).toList();
      if (byPrimary.isEmpty) continue;

      final knownSubs = kSubcategories[primary] ?? <String>[];
      final grouped = <String?, List<MarketMakerProfile>>{};
      for (final m in byPrimary) {
        final key =
            knownSubs.contains(m.subcategory) ? m.subcategory : null;
        (grouped[key] ??= []).add(m);
      }

      // Known subcategories in defined order
      for (final sub in knownSubs) {
        final group = grouped[sub];
        if (group != null && group.isNotEmpty) {
          sections.add(_CategorySection(
              primary: primary, subcategory: sub, makers: group));
        }
      }

      // General section for makers with null or unrecognised subcategory
      final general = grouped[null];
      if (general != null && general.isNotEmpty) {
        sections.add(_CategorySection(
            primary: primary, subcategory: null, makers: general));
      }
    }

    return sections;
  }
}

class _CategorySection {
  final String primary;
  final String? subcategory;
  final List<MarketMakerProfile> makers;

  const _CategorySection({
    required this.primary,
    this.subcategory,
    required this.makers,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// LIVE BATTLE MARKETS — back team 1 or team 2 on an active battle
// ─────────────────────────────────────────────────────────────────────────────

class _BattleMarketsSection extends ConsumerWidget {
  const _BattleMarketsSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final battles = ref.watch(battleMarketsProvider).valueOrNull ?? const [];
    if (battles.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
          child: Text(
            '⚔️ Live Battle Markets',
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        ...battles.map((b) => Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: _BattleMarketCard(
                market: b,
                onBetPlaced: () => ref.invalidate(battleMarketsProvider),
              ),
            )),
        const SizedBox(height: 20),
      ],
    );
  }
}

class _BattleMarketCard extends StatelessWidget {
  final BattleMarket market;
  final VoidCallback onBetPlaced;

  const _BattleMarketCard({required this.market, required this.onBetPlaced});

  @override
  Widget build(BuildContext context) {
    final total = market.totalPool;
    final t1Ratio = total > 0 ? market.team1Pool / total : 0.5;

    return NTappable(
      onTap: () =>
          showBattleBetSheet(context, market: market, onBetPlaced: onBetPlaced),
      child: Container(
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
              children: [
                Expanded(
                  child: Text(
                    '${market.team1Label} vs ${market.team2Label}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
                Text(
                  '${total.toStringAsFixed(0)} tokens',
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 10),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: SizedBox(
                height: 8,
                child: Row(children: [
                  Expanded(
                      flex: (t1Ratio * 100).round().clamp(1, 100),
                      child: Container(color: AppTheme.success)),
                  Expanded(
                      flex: ((1 - t1Ratio) * 100).round().clamp(1, 100),
                      child: Container(color: AppTheme.primary)),
                ]),
              ),
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(market.team1Label,
                    style: const TextStyle(
                        color: AppTheme.success,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
                Text(market.team2Label,
                    style: const TextStyle(
                        color: AppTheme.primary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600)),
              ],
            ),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerRight,
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
                decoration: BoxDecoration(
                  color: AppTheme.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text('Back a team',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SECTION HEADER
// ─────────────────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String primary;
  final String? subcategory;
  final bool showPrimary;

  const _SectionHeader({
    required this.primary,
    this.subcategory,
    required this.showPrimary,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showPrimary)
            Text(
              '${primary}s',
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          if (subcategory != null)
            Text(
              subcategory!,
              style: TextStyle(
                color: showPrimary
                    ? AppTheme.secondary
                    : AppTheme.textPrimary,
                fontSize: showPrimary ? 13 : 18,
                fontWeight:
                    showPrimary ? FontWeight.w500 : FontWeight.bold,
              ),
            )
          else
            Text(
              'General',
              style: TextStyle(
                color: showPrimary ? AppTheme.textSecondary : AppTheme.textPrimary,
                fontSize: showPrimary ? 13 : 18,
                fontWeight: showPrimary ? FontWeight.normal : FontWeight.bold,
              ),
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HORIZONTAL ROW OF CIRCULAR CREATOR CARDS
// ─────────────────────────────────────────────────────────────────────────────

class _HorizontalCreatorRow extends StatelessWidget {
  final List<MarketMakerProfile> makers;
  const _HorizontalCreatorRow({required this.makers});

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: makers
            .map((m) => Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: _CreatorCard(maker: m),
                ))
            .toList(),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CIRCULAR CREATOR CARD
// ─────────────────────────────────────────────────────────────────────────────

class _CreatorCard extends StatelessWidget {
  final MarketMakerProfile maker;
  const _CreatorCard({required this.maker});

  Color _avatarColor(String username) {
    const palette = [
      Color(0xFF6C63FF), Color(0xFF00C896), Color(0xFFFF6B35),
      Color(0xFFEE1D52), Color(0xFF9146FF), Color(0xFFFFD700),
      Color(0xFF00BCD4),
    ];
    final index =
        username.codeUnits.fold(0, (sum, c) => sum + c) % palette.length;
    return palette[index];
  }

  @override
  Widget build(BuildContext context) {
    final color = _avatarColor(maker.username);
    final initial =
        maker.username.isNotEmpty ? maker.username[0].toUpperCase() : '?';

    return NTappable(
      onTap: () => context.go('/u/${maker.username}'),
      child: SizedBox(
        width: 110,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Circular avatar with optional live ring
            Stack(
              alignment: Alignment.bottomCenter,
              children: [
                Container(
                  width: 90,
                  height: 90,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: maker.isLive
                        ? Border.all(
                            color: const Color(0xFFFF4757), width: 3)
                        : null,
                  ),
                  child: CircleAvatar(
                    radius: 45,
                    backgroundColor: color.withValues(alpha: 0.25),
                    child: Text(
                      initial,
                      style: TextStyle(
                        color: color,
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
                if (maker.isLive)
                  Positioned(
                    bottom: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF4757),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'LIVE',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            // Username
            Text(
              '@${maker.username}',
              textAlign: TextAlign.center,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
            if (maker.subcategory != null) ...[
              const SizedBox(height: 2),
              Text(
                maker.subcategory!,
                textAlign: TextAlign.center,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white54,
                  fontSize: 11,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FILTER CHIP
// ─────────────────────────────────────────────────────────────────────────────

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
    return NTappable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
        decoration: BoxDecoration(
          color: selected ? AppTheme.primary : AppTheme.surface,
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
