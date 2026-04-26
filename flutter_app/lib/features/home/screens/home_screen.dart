import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shimmer/shimmer.dart';
import 'package:timeago/timeago.dart' as timeago;
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/open_url.dart';
import '../../auth/providers/auth_provider.dart';
import '../../challenges/providers/challenge_providers.dart';
import '../../notifications/providers/notification_providers.dart';
import '../../discover/providers/discover_providers.dart';
import '../../profile/providers/platform_connection_providers.dart';
import '../../profile/providers/profile_providers.dart';
import '../../profile/models/platform_metric.dart';
import '../providers/home_providers.dart';
import '../widgets/home_ticker.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../wallet/providers/wallet_providers.dart';
import '../../wallet/widgets/buy_tokens_sheet.dart';

final _checkInProvider = FutureProvider.autoDispose<void>((ref) async {
  final actions = ref.read(challengeActionsProvider);
  await actions.fireCheckIn();
});

const _kAccentPalette = [
  Color(0xFF6C63FF), Color(0xFF00C896), Color(0xFFFF6B35),
  Color(0xFFEE1D52), Color(0xFF9146FF), Color(0xFFFFD700),
  Color(0xFF00BCD4),
];

Color _paletteColor(String label) {
  final code = label.codeUnits.fold(0, (s, c) => s + c);
  return _kAccentPalette[code % _kAccentPalette.length];
}

const _kCategories = [
  'Trending', 'Athletes', 'Influencers', 'Artists',
  'Scientists', 'Professionals',
];

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  int _categoryIndex = 0;
  int _spotlightSlide = 0;
  final GlobalKey<ScaffoldState> _scaffoldKey = GlobalKey<ScaffoldState>();

  @override
  void initState() {
    super.initState();
    ref.read(_checkInProvider.future).ignore();
  }

  @override
  Widget build(BuildContext context) {
    final isWide = MediaQuery.of(context).size.width >= 900;

    return Scaffold(
      key: _scaffoldKey,
      backgroundColor: AppTheme.background,
      drawer: const _SideDrawer(),
      body: SafeArea(
        child: Column(
          children: [
            _Header(scaffoldKey: _scaffoldKey),
            const HomeTicker(),
            _CategoryTabs(
              selected: _categoryIndex,
              onSelect: (i) => setState(() => _categoryIndex = i),
            ),
            Expanded(
              child: RefreshIndicator(
                color: AppTheme.primary,
                backgroundColor: AppTheme.surface,
                onRefresh: _refresh,
                child: CustomScrollView(
                  slivers: [
                    SliverToBoxAdapter(
                      child: isWide
                          ? _WideSpotlightLayout(
                              slide: _spotlightSlide,
                              onSlide: (i) => setState(() => _spotlightSlide = i),
                            )
                          : _NarrowSpotlightLayout(
                              slide: _spotlightSlide,
                              onSlide: (i) => setState(() => _spotlightSlide = i),
                            ),
                    ),
                    const SliverToBoxAdapter(child: _Divider()),
                    const SliverToBoxAdapter(child: _RisingSection()),
                    const SliverToBoxAdapter(child: _WhoIsLiveSection()),
                    const SliverToBoxAdapter(child: _FooterLinks()),
                    const SliverToBoxAdapter(child: SizedBox(height: 24)),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _refresh() async {
    ref.invalidate(spotlightCreatorsProvider);
    ref.invalidate(risingCreatorsProvider);
    ref.invalidate(liveUserIdsProvider);
    ref.invalidate(liveMetricsFeedProvider);
    ref.invalidate(homeTokenBalanceProvider);
  }
}

// ─── Header ──────────────────────────────────────────────────────────────────

class _Header extends ConsumerWidget {
  final GlobalKey<ScaffoldState> scaffoldKey;
  const _Header({required this.scaffoldKey});

  void _openNotifications(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => const _NotificationSheet(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final isLoggedIn = user != null;
    final unreadCount =
        isLoggedIn ? ref.watch(unreadCountProvider) : 0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: Color(0xED0A0A0F),
        border: Border(bottom: BorderSide(color: AppTheme.cardBorder)),
      ),
      child: Row(
        children: [
          // Hamburger
          IconButton(
            icon: const Icon(Icons.menu,
                color: AppTheme.textPrimary, size: 22),
            onPressed: () => scaffoldKey.currentState?.openDrawer(),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
          ),
          const SizedBox(width: 8),
          // Logo
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              border: Border.all(color: AppTheme.cardBorder),
              borderRadius: BorderRadius.circular(8),
            ),
            child: const Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('N.O.R.A. Platforms',
                    style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 12,
                        fontWeight: FontWeight.w800)),
                Text('Phase 1',
                    style: TextStyle(
                        color: AppTheme.textSecondary, fontSize: 10)),
              ],
            ),
          ),
          if (isLoggedIn) ...[
            const Spacer(),
            // Notification bell with unread badge
            Stack(
              clipBehavior: Clip.none,
              children: [
                IconButton(
                  icon: const Icon(Icons.notifications_outlined,
                      color: AppTheme.textSecondary, size: 22),
                  onPressed: () => _openNotifications(context),
                  padding: EdgeInsets.zero,
                  constraints:
                      const BoxConstraints(minWidth: 36, minHeight: 36),
                ),
                if (unreadCount > 0)
                  Positioned(
                    right: 2, top: 2,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                          color: AppTheme.danger, shape: BoxShape.circle),
                      constraints:
                          const BoxConstraints(minWidth: 15, minHeight: 15),
                      child: Text(
                        unreadCount > 99 ? '99+' : '$unreadCount',
                        style: const TextStyle(
                            color: Colors.white,
                            fontSize: 8,
                            fontWeight: FontWeight.bold),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 6),
            // Get Tokens — opens purchase sheet without leaving home screen
            GestureDetector(
              onTap: () => showBuyTokensSheet(context),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: AppTheme.secondary.withValues(alpha: 0.12),
                  border: Border.all(
                      color: AppTheme.secondary.withValues(alpha: 0.5)),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'Get Tokens',
                  style: TextStyle(
                    color: AppTheme.secondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ] else ...[
            // Center: "Learn more" button
            const SizedBox(width: 12),
            Expanded(
              child: Center(
                child: OutlinedButton(
                  onPressed: () => GoRouter.of(context).go('/plan'),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: AppTheme.primary),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8)),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 10),
                  ),
                  child: const Text(
                    'Learn more about Phase 2 and Phase 3',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            GestureDetector(
              onTap: () => GoRouter.of(context).go('/login'),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  border: Border.all(color: AppTheme.cardBorder),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'Login',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => GoRouter.of(context).go('/signup'),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 7),
                decoration: BoxDecoration(
                  color: AppTheme.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Text(
                  'Sign Up',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─── Category tabs ────────────────────────────────────────────────────────────

class _CategoryTabs extends StatelessWidget {
  final int selected;
  final ValueChanged<int> onSelect;
  const _CategoryTabs({required this.selected, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.cardBorder)),
      ),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            ..._kCategories.asMap().entries.map((e) {
              final active = e.key == selected;
              return _TabButton(
                label: e.value,
                active: active,
                onTap: () => onSelect(e.key),
              );
            }),
            _TabButton(
              label: 'Explore All →',
              active: false,
              accent: true,
              onTap: () => GoRouter.of(context).go('/markets'),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  final String label;
  final bool active;
  final bool accent;
  final VoidCallback onTap;
  const _TabButton({
    required this.label,
    required this.active,
    required this.onTap,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final color = accent
        ? AppTheme.primary
        : active
            ? AppTheme.textPrimary
            : AppTheme.textSecondary;
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 13),
        decoration: BoxDecoration(
          border: Border(
            bottom: BorderSide(
              color: active ? AppTheme.primary : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: color,
            fontSize: 13,
            fontWeight: active || accent ? FontWeight.w600 : FontWeight.w400,
          ),
        ),
      ),
    );
  }
}

// TODO (post Arena Phase A): Split Weekly Spotlight section into
// "Arena Champions" (5 slots) and "Top Movers" (5 slots).
// Champions sourced from previous week's Round 3 winners.
// Top Movers sourced from trailing 7-day display_score growth.

// ─── Wide spotlight layout (≥900px) ──────────────────────────────────────────

class _WideSpotlightLayout extends ConsumerWidget {
  final int slide;
  final ValueChanged<int> onSlide;
  const _WideSpotlightLayout({required this.slide, required this.onSlide});

  Widget _buildRankSidebar(List<SpotlightCreator> creators, int safeSlide) {
    final others = creators
        .asMap()
        .entries
        .where((e) => e.key != safeSlide)
        .take(4)
        .toList();
    return Column(
      children: List.generate(4, (i) {
        final rank = i + 2; // 2nd through 5th
        if (i < others.length) {
          final e = others[i];
          return _RankCard(
            creator: e.value,
            rank: e.key + 1,
            isActive: false,
            onTap: () => onSlide(e.key),
          );
        }
        return _PlaceholderRankCard(rank: rank);
      }),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final creatorsAsync = ref.watch(spotlightCreatorsProvider);
    final creators = creatorsAsync.valueOrNull ?? [];
    final safeSlide = creators.isEmpty ? 0 : slide.clamp(0, creators.length - 1);

    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Heading — always visible
          Row(
            children: [
              Text(
                creators.isEmpty ? '1st' : _ordinal(safeSlide),
                style: const TextStyle(
                  color: AppTheme.primary,
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(width: 12),
              const Text(
                'Weekly Spotlight',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          // 3-column row — always visible, never collapses
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 420),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Main spotlight card — flex 5
                Expanded(
                  flex: 5,
                  child: creators.isEmpty
                      ? const _SpotlightPlaceholderCard(height: 400)
                      : _SpotlightCard(
                          creator: creators[safeSlide],
                          height: 400,
                          slide: safeSlide,
                          total: creators.length,
                          onPrev: safeSlide > 0
                              ? () => onSlide(safeSlide - 1)
                              : null,
                          onNext: safeSlide < creators.length - 1
                              ? () => onSlide(safeSlide + 1)
                              : null,
                          onDot: onSlide,
                        ),
                ),
                const SizedBox(width: 12),
                // Rank sidebar — flex 2 — always shows 4 cards
                Expanded(
                  flex: 2,
                  child: _buildRankSidebar(creators, safeSlide),
                ),
                const SizedBox(width: 12),
                // Right column: news + tokens — flex 2 — always visible
                Expanded(
                  flex: 2,
                  child: Column(
                    children: [
                      _NewsPanel(),
                      const SizedBox(height: 14),
                      _GetTokensButton(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Narrow spotlight layout (<900px) ────────────────────────────────────────

class _NarrowSpotlightLayout extends ConsumerWidget {
  final int slide;
  final ValueChanged<int> onSlide;
  const _NarrowSpotlightLayout({required this.slide, required this.onSlide});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final creatorsAsync = ref.watch(spotlightCreatorsProvider);
    final creators = creatorsAsync.valueOrNull ?? [];
    final safeSlide = creators.isEmpty ? 0 : slide.clamp(0, creators.length - 1);

    final others = creators
        .asMap()
        .entries
        .where((e) => e.key != safeSlide)
        .take(4)
        .toList();

    return Padding(
      padding: const EdgeInsets.all(16),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 420),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Heading — always visible
            Row(
              children: [
                Text(
                  creators.isEmpty ? '1st' : _ordinal(safeSlide),
                  style: const TextStyle(
                      color: AppTheme.primary,
                      fontSize: 22,
                      fontWeight: FontWeight.w800),
                ),
                const SizedBox(width: 10),
                const Text('Weekly Spotlight',
                    style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 18,
                        fontWeight: FontWeight.w700)),
              ],
            ),
            const SizedBox(height: 12),
            // Carousel — full width, always visible
            creators.isEmpty
                ? const _SpotlightPlaceholderCard(height: 300)
                : _SpotlightCard(
                    creator: creators[safeSlide],
                    height: 300,
                    slide: safeSlide,
                    total: creators.length,
                    onPrev: safeSlide > 0
                        ? () => onSlide(safeSlide - 1)
                        : null,
                    onNext: safeSlide < creators.length - 1
                        ? () => onSlide(safeSlide + 1)
                        : null,
                    onDot: onSlide,
                  ),
            const SizedBox(height: 12),
            // Rank cards — always show 4
            ...List.generate(4, (i) {
              final rank = i + 2;
              if (i < others.length) {
                final e = others[i];
                return _RankCard(
                  creator: e.value,
                  rank: e.key + 1,
                  isActive: false,
                  onTap: () => onSlide(e.key),
                );
              }
              return _PlaceholderRankCard(rank: rank);
            }),
            const SizedBox(height: 16),
            _NewsPanel(),
            const SizedBox(height: 12),
            _GetTokensButton(),
          ],
        ),
      ),
    );
  }
}

// ─── Spotlight card ───────────────────────────────────────────────────────────

class _SpotlightCard extends StatelessWidget {
  final SpotlightCreator creator;
  final int slide;
  final int total;
  final VoidCallback? onPrev;
  final VoidCallback? onNext;
  final ValueChanged<int> onDot;
  final double height;

  const _SpotlightCard({
    required this.creator,
    required this.slide,
    required this.total,
    required this.onPrev,
    required this.onNext,
    required this.onDot,
    this.height = 400,
  });

  @override
  Widget build(BuildContext context) {
    final accent = _paletteColor(creator.displayLabel);
    final card = Container(
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
      ),
      child: Stack(
        children: [
          // Layer 1 — full-bleed background image or gradient placeholder
          Positioned.fill(
            child: creator.avatarUrl != null
                ? Image.network(
                    creator.avatarUrl!,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _CardGradient(accent: accent),
                  )
                : _CardGradient(accent: accent),
          ),
          // Layer 2 — bottom gradient fade (covers bottom 40%)
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.4, 1.0],
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.75),
                  ],
                ),
              ),
            ),
          ),
          // Layer 3 — score chip (top-right)
          Positioned(
            top: 16, right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A2E).withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.trending_up,
                      color: Color(0xFF00C896), size: 14),
                  const SizedBox(width: 5),
                  Text(
                    '+${creator.score.toStringAsFixed(0)} pts',
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w700),
                  ),
                ],
              ),
            ),
          ),
          // Layer 4 — follower count overlay (bottom-left)
          Positioned(
            bottom: 60, left: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.70),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('FOLLOWER COUNT',
                      style: TextStyle(
                          color: Colors.white54,
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.8)),
                  const SizedBox(height: 4),
                  Text('Score: +${creator.score.toStringAsFixed(0)}',
                      style: const TextStyle(
                          color: Color(0xFF00C896),
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
          // Layer 5 — creator name + category (bottom-right)
          Positioned(
            bottom: 60, right: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(creator.displayLabel,
                    style: const TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold)),
                const SizedBox(height: 3),
                Text(creator.tier,
                    style: const TextStyle(
                        color: Colors.white70, fontSize: 14)),
              ],
            ),
          ),
          // Layer 6 — navigation arrows
          if (onPrev != null)
            Positioned(
              left: 8, top: 0, bottom: 0,
              child: Center(
                  child: _ChevronButton(
                      icon: Icons.chevron_left, onTap: onPrev!)),
            ),
          if (onNext != null)
            Positioned(
              right: 8, top: 0, bottom: 0,
              child: Center(
                  child: _ChevronButton(
                      icon: Icons.chevron_right, onTap: onNext!)),
            ),
        ],
      ),
    );

    // Dots placed below the card, not inside the Stack
    if (total <= 1) return card;
    return Column(
      children: [
        card,
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: List.generate(total, (i) {
            final active = i == slide;
            return GestureDetector(
              onTap: () => onDot(i),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 250),
                margin: const EdgeInsets.symmetric(horizontal: 3),
                width: active ? 8 : 6,
                height: active ? 8 : 6,
                decoration: BoxDecoration(
                  color: active
                      ? const Color(0xFF6C63FF)
                      : Colors.white30,
                  shape: BoxShape.circle,
                ),
              ),
            );
          }),
        ),
      ],
    );
  }
}

class _CardGradient extends StatelessWidget {
  final Color accent;
  const _CardGradient({required this.accent});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        gradient: RadialGradient(
          center: const Alignment(0, -0.6),
          radius: 1.2,
          colors: [
            accent.withValues(alpha: 0.55),
            accent.withValues(alpha: 0.15),
            AppTheme.background,
          ],
        ),
      ),
    );
  }
}

// ─── Spotlight placeholder card (shown when no data or loading) ───────────────

class _SpotlightPlaceholderCard extends StatelessWidget {
  final double height;
  const _SpotlightPlaceholderCard({this.height = 400});

  @override
  Widget build(BuildContext context) {
    final card = Container(
      height: height,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(borderRadius: BorderRadius.circular(12)),
      child: Stack(
        children: [
          // Dark gradient background
          Positioned.fill(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [Color(0xFF1A1A2E), Color(0xFF0A0A0F)],
                ),
              ),
            ),
          ),
          // Bottom fade
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: const [0.4, 1.0],
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.75),
                  ],
                ),
              ),
            ),
          ),
          // Score chip top-right — placeholder
          Positioned(
            top: 16, right: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A2E).withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(20),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.trending_up, color: Color(0xFF00C896), size: 14),
                  SizedBox(width: 5),
                  Text('-- pts',
                      style: TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w700)),
                ],
              ),
            ),
          ),
          // Follower count bottom-left — placeholder
          Positioned(
            bottom: 60, left: 16,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.70),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('FOLLOWER COUNT',
                      style: TextStyle(
                          color: Colors.white54,
                          fontSize: 9,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 0.8)),
                  SizedBox(height: 4),
                  Text('—  —  —',
                      style: TextStyle(
                          color: Color(0xFF00C896),
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
          // Creator name + category bottom-right — placeholder
          const Positioned(
            bottom: 60, right: 16,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('Weekly Spotlight',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 22,
                        fontWeight: FontWeight.bold)),
                SizedBox(height: 3),
                Text('Connect platforms to appear here',
                    style: TextStyle(color: Colors.white70, fontSize: 14)),
              ],
            ),
          ),
          // Left chevron — disabled
          Positioned(
            left: 8, top: 0, bottom: 0,
            child: Center(
              child: Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.30),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.chevron_left,
                    color: Colors.white30, size: 24),
              ),
            ),
          ),
          // Right chevron — disabled
          Positioned(
            right: 8, top: 0, bottom: 0,
            child: Center(
              child: Container(
                width: 40, height: 40,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.30),
                  shape: BoxShape.circle,
                ),
                child: const Icon(Icons.chevron_right,
                    color: Colors.white30, size: 24),
              ),
            ),
          ),
        ],
      ),
    );

    // Single dot indicator below
    return Column(
      children: [
        card,
        const SizedBox(height: 10),
        const Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            SizedBox(
              width: 8, height: 8,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: Color(0xFF6C63FF),
                  shape: BoxShape.circle,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }
}

class _ChevronButton extends StatelessWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _ChevronButton({required this.icon, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 40, height: 40,
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.50),
          shape: BoxShape.circle,
        ),
        child: Icon(icon, color: Colors.white, size: 24),
      ),
    );
  }
}

// ─── Rank card ────────────────────────────────────────────────────────────────

class _RankCard extends StatelessWidget {
  final SpotlightCreator creator;
  final int rank;
  final bool isActive;
  final VoidCallback onTap;
  const _RankCard({
    required this.creator,
    required this.rank,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accent = _paletteColor(creator.displayLabel);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 64,
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF1A1A2E),
          border: Border.all(color: Colors.white10),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            Text(_ordinal(rank - 1),
                style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                    fontWeight: FontWeight.w700)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(creator.displayLabel,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis),
                  Text(creator.tier,
                      style: const TextStyle(
                          color: Colors.white54, fontSize: 11)),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Avatar — photo if available, else colored initial
            creator.avatarUrl != null
                ? CircleAvatar(
                    radius: 17,
                    backgroundImage: NetworkImage(creator.avatarUrl!),
                    onBackgroundImageError: (_, __) {},
                  )
                : Container(
                    width: 34, height: 34,
                    decoration: BoxDecoration(
                      color: accent.withValues(alpha: 0.20),
                      shape: BoxShape.circle,
                    ),
                    child: Center(
                      child: Text(
                        creator.initials,
                        style: TextStyle(
                            color: accent,
                            fontSize: 14,
                            fontWeight: FontWeight.w800),
                      ),
                    ),
                  ),
          ],
        ),
      ),
    );
  }
}

// ─── Placeholder rank card (shown when fewer than 4 real creators exist) ──────

class _PlaceholderRankCard extends StatelessWidget {
  final int rank; // 2–5
  const _PlaceholderRankCard({required this.rank});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 64,
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF1A1A2E),
        border: Border.all(color: Colors.white10),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Text(_ordinal(rank - 1),
              style: const TextStyle(
                  color: AppTheme.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700)),
          const SizedBox(width: 10),
          const Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('—',
                    style: TextStyle(
                        color: Colors.white54,
                        fontSize: 13,
                        fontWeight: FontWeight.bold)),
                Text('No data yet',
                    style:
                        TextStyle(color: Colors.white38, fontSize: 11)),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Container(
            width: 34, height: 34,
            decoration: const BoxDecoration(
              color: Colors.white12,
              shape: BoxShape.circle,
            ),
            child: const Center(
              child: Text('?',
                  style: TextStyle(
                      color: Colors.white38,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── News panel ───────────────────────────────────────────────────────────────

// TODO: wire to news API — currently static placeholder headlines
class _NewsPanel extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border.all(color: AppTheme.cardBorder),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          GestureDetector(
            onTap: () => GoRouter.of(context).go('/news'),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: const Color(0xFFE53935),
                borderRadius: BorderRadius.circular(999),
              ),
              child: const Text('Breaking News',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w700)),
            ),
          ),
          const SizedBox(height: 12),
          const _TappableNewsItem(
              text: 'JordanKicks breaks 1M followers',
              time: '2m ago'),
          const _NewsDivider(),
          const _TappableNewsItem(
              text: 'New weekly score record set by CreatorKing',
              time: '14m ago'),
          const _NewsDivider(),
          const _TappableNewsItem(
              text: 'BeatMaster drops surprise album — fans react',
              time: '1h ago'),
        ],
      ),
    );
  }
}

class _TappableNewsItem extends StatelessWidget {
  final String text;
  final String time;
  const _TappableNewsItem({required this.text, required this.time});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => GoRouter.of(context).go('/news'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(text,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: AppTheme.textPrimary, fontSize: 13, height: 1.5)),
          const SizedBox(height: 2),
          Text(time,
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 11)),
        ],
      ),
    );
  }
}

class _NewsDivider extends StatelessWidget {
  const _NewsDivider();

  @override
  Widget build(BuildContext context) => const Padding(
        padding: EdgeInsets.symmetric(vertical: 8),
        child: Divider(color: AppTheme.cardBorder, height: 1),
      );
}

// ─── Get Tokens button ────────────────────────────────────────────────────────

class _GetTokensButton extends StatelessWidget {
  void _open(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (_) => const _GetTokensSheet(),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _open(context),
      child: Container(
        width: double.infinity,
        height: 80,
        decoration: BoxDecoration(
          color: AppTheme.surface,
          border: Border.all(color: AppTheme.secondary),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Center(
          child: Text(
            'Get Tokens',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800),
          ),
        ),
      ),
    );
  }
}

// ─── Unified Get Tokens sheet (choose → purchase / earn, all in one modal) ───

enum _GetTokensView { choose, purchase, earn }

class _GetTokensSheet extends StatefulWidget {
  const _GetTokensSheet();

  @override
  State<_GetTokensSheet> createState() => _GetTokensSheetState();
}

class _GetTokensSheetState extends State<_GetTokensSheet> {
  _GetTokensView _view = _GetTokensView.choose;
  String? _loadingPackageId;

  Future<void> _onPackageTap(TokenPackage pkg) async {
    if (_loadingPackageId != null) return;
    setState(() => _loadingPackageId = pkg.id);
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
      if (mounted) setState(() => _loadingPackageId = null);
    }
  }

  Widget _buildDragHandle() => Center(
        child: Container(
          width: 40,
          height: 4,
          decoration: BoxDecoration(
            color: AppTheme.cardBorder,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
      );

  Widget _buildSubViewHeader(String title) => Row(
        children: [
          GestureDetector(
            onTap: () => setState(() => _view = _GetTokensView.choose),
            child: Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: AppTheme.cardBorder,
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(Icons.arrow_back,
                  color: AppTheme.textPrimary, size: 18),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            title,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      );

  List<Widget> _chooseView() => [
        const Text(
          'Get Tokens',
          style: TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 4),
        const Text(
          'Choose how you want to get tokens',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 20),
        _OptionCard(
          icon: Icons.shopping_bag_outlined,
          label: 'Purchase',
          subtitle: 'Buy token packages',
          iconColor: AppTheme.secondary,
          onTap: () => setState(() => _view = _GetTokensView.purchase),
        ),
        const SizedBox(height: 12),
        _OptionCard(
          icon: Icons.sports_esports_outlined,
          label: 'Earn',
          subtitle: 'Play games to earn free tokens',
          iconColor: AppTheme.primary,
          onTap: () => setState(() => _view = _GetTokensView.earn),
        ),
      ];

  List<Widget> _purchaseView() => [
        _buildSubViewHeader('Buy Tokens'),
        const SizedBox(height: 4),
        const Padding(
          padding: EdgeInsets.only(left: 48),
          child: Text(
            'Tokens fuel promotions, bets, and power-ups.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
        ),
        const SizedBox(height: 20),
        ...kTokenPackages.map((pkg) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _PurchasePackageCard(
                pkg: pkg,
                isLoading: _loadingPackageId == pkg.id,
                disabled:
                    _loadingPackageId != null && _loadingPackageId != pkg.id,
                onTap: () => _onPackageTap(pkg),
              ),
            )),
      ];

  List<Widget> _earnView() => [
        _buildSubViewHeader('Earn Tokens'),
        const SizedBox(height: 4),
        const Padding(
          padding: EdgeInsets.only(left: 48),
          child: Text(
            'Play games to earn free tokens',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
        ),
        const SizedBox(height: 20),
        ..._kEarnGames.map((g) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _EarnGameCard(icon: g.icon, label: g.label),
            )),
      ];

  @override
  Widget build(BuildContext context) {
    final viewWidgets = switch (_view) {
      _GetTokensView.choose   => _chooseView(),
      _GetTokensView.purchase => _purchaseView(),
      _GetTokensView.earn     => _earnView(),
    };

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _buildDragHandle(),
            const SizedBox(height: 20),
            ...viewWidgets,
          ],
        ),
      ),
    );
  }
}

// ─── Earn games catalogue ─────────────────────────────────────────────────────

const _kEarnGames = [
  (icon: Icons.shield_outlined,              label: 'Arena'),
  (icon: Icons.local_fire_department_outlined, label: 'Hot Topic'),
  (icon: Icons.egg_outlined,                 label: 'Chicken Run'),
  (icon: Icons.sports_basketball_outlined,   label: 'Ball Bounce'),
];

// ─── Option card (choose view) ────────────────────────────────────────────────

class _OptionCard extends StatelessWidget {
  const _OptionCard({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.iconColor,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final String subtitle;
  final Color iconColor;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: AppTheme.surfaceLight,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(subtitle,
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 13)),
                ],
              ),
            ),
            const Icon(Icons.chevron_right, color: AppTheme.textSecondary),
          ],
        ),
      ),
    );
  }
}

// ─── Purchase package card ────────────────────────────────────────────────────

class _PurchasePackageCard extends StatelessWidget {
  const _PurchasePackageCard({
    required this.pkg,
    required this.isLoading,
    required this.disabled,
    required this.onTap,
  });

  final TokenPackage pkg;
  final bool isLoading;
  final bool disabled;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final isPopular = pkg.badge == 'Most Popular';
    return Material(
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
                        strokeWidth: 2, color: AppTheme.primary),
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
    );
  }
}

// ─── Earn game card ───────────────────────────────────────────────────────────

class _EarnGameCard extends StatelessWidget {
  const _EarnGameCard({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppTheme.surfaceLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: AppTheme.primary, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Text(label,
                style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w700)),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.cardBorder,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Text(
              'Coming Soon',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Rising section ───────────────────────────────────────────────────────────

class _RisingSection extends ConsumerWidget {
  const _RisingSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final creatorsAsync = ref.watch(risingCreatorsProvider);
    final liveIds = ref.watch(liveUserIdsProvider).valueOrNull ?? {};

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.bolt, color: Color(0xFFFFD700), size: 18),
              SizedBox(width: 6),
              Text('Rising',
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w700)),
              SizedBox(width: 8),
              Text('Market Makers gaining traction',
                  style: TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 12),
          SizedBox(
            height: 120,
            child: creatorsAsync.when(
              loading: () => _shimmerRow(),
              error: (_, __) => const SizedBox.shrink(),
              data: (creators) {
                if (creators.isEmpty) {
                  return ListView(
                    scrollDirection: Axis.horizontal,
                    children: const [
                      _RisingPlaceholderTile(),
                      _RisingPlaceholderTile(),
                      _RisingPlaceholderTile(),
                    ],
                  );
                }
                return ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: creators.length,
                  itemBuilder: (context, i) => _RisingTile(
                    creator: creators[i],
                    isLive: liveIds.contains(creators[i].id),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _shimmerRow() => Shimmer.fromColors(
        baseColor: AppTheme.surface,
        highlightColor: AppTheme.cardBorder,
        child: Row(
          children: List.generate(
            5,
            (_) => Container(
              width: 110,
              margin: const EdgeInsets.only(right: 12),
              decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
      );
}

class _RisingTile extends StatelessWidget {
  final RisingCreator creator;
  final bool isLive;
  const _RisingTile({required this.creator, required this.isLive});

  @override
  Widget build(BuildContext context) {
    final color = _paletteColor(creator.displayLabel);
    return Container(
      width: 110,
      margin: const EdgeInsets.only(right: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border.all(
            color: isLive
                ? AppTheme.danger.withValues(alpha: 0.5)
                : AppTheme.cardBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Stack(
            clipBehavior: Clip.none,
            children: [
              Container(
                width: 44, height: 44,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  shape: BoxShape.circle,
                  border: Border.all(color: color.withValues(alpha: 0.4), width: 1.5),
                ),
                child: Center(
                  child: Text(
                    creator.displayLabel.isNotEmpty
                        ? creator.displayLabel[0].toUpperCase()
                        : '?',
                    style: TextStyle(
                        color: color,
                        fontSize: 18,
                        fontWeight: FontWeight.w700),
                  ),
                ),
              ),
              if (isLive)
                Positioned(
                  right: -2, top: -2,
                  child: Container(
                    width: 10, height: 10,
                    decoration: BoxDecoration(
                      color: AppTheme.danger,
                      shape: BoxShape.circle,
                      border: Border.all(
                          color: AppTheme.background, width: 1.5),
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            creator.displayLabel,
            style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 12,
                fontWeight: FontWeight.w600),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _RisingPlaceholderTile extends StatelessWidget {
  const _RisingPlaceholderTile();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 110,
      margin: const EdgeInsets.only(right: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border.all(color: AppTheme.cardBorder),
        borderRadius: BorderRadius.circular(14),
      ),
      child: const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          SizedBox(
            width: 44, height: 44,
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.white12,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.person, color: Colors.white24, size: 22),
            ),
          ),
          SizedBox(height: 8),
          Text('Creator',
              style: TextStyle(
                  color: Colors.white38,
                  fontSize: 12,
                  fontWeight: FontWeight.w600),
              textAlign: TextAlign.center),
          Text('Connect\nplatforms',
              style: TextStyle(color: Colors.white24, fontSize: 9),
              textAlign: TextAlign.center,
              maxLines: 2),
        ],
      ),
    );
  }
}

// ─── Who's Live section ───────────────────────────────────────────────────────

class _WhoIsLiveSection extends ConsumerWidget {
  const _WhoIsLiveSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final feedAsync = ref.watch(liveMetricsFeedProvider);

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 0, 24, 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.radio, color: AppTheme.danger, size: 18),
              SizedBox(width: 6),
              Text("Who's Live",
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w700)),
              SizedBox(width: 8),
              Text('Creators streaming right now',
                  style: TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12)),
            ],
          ),
          const SizedBox(height: 12),
          feedAsync.when(
            loading: () => _shimmerList(),
            error: (_, __) => const SizedBox.shrink(),
            data: (metrics) {
              if (metrics.isEmpty) {
                return const Padding(
                  padding: EdgeInsets.symmetric(vertical: 24),
                  child: Center(
                    child: Column(
                      children: [
                        Icon(Icons.live_tv_outlined,
                            size: 36, color: AppTheme.textSecondary),
                        SizedBox(height: 10),
                        Text('No creators are live right now',
                            style: TextStyle(color: AppTheme.textSecondary)),
                      ],
                    ),
                  ),
                );
              }
              return Column(
                children: metrics
                    .map((m) => _LiveCard(metric: m))
                    .toList(),
              );
            },
          ),
        ],
      ),
    );
  }

  Widget _shimmerList() => Shimmer.fromColors(
        baseColor: AppTheme.surface,
        highlightColor: AppTheme.cardBorder,
        child: Column(
          children: List.generate(
            3,
            (_) => Container(
              height: 100,
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(16)),
            ),
          ),
        ),
      );
}

class _LiveCard extends StatelessWidget {
  final PlatformMetric metric;
  const _LiveCard({required this.metric});

  String _fmtViewers(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }

  @override
  Widget build(BuildContext context) {
    final isYT = metric.platform == 'youtube';
    final label = isYT ? 'YT' : 'Twitch';
    final color = isYT ? const Color(0xFFFF4444) : const Color(0xFF9146FF);

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border.all(color: AppTheme.cardBorder),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  border: Border.all(color: color.withValues(alpha: 0.35)),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(label,
                    style: TextStyle(
                        color: color,
                        fontSize: 11,
                        fontWeight: FontWeight.w600)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  metric.platformUsername != null
                      ? '@${metric.platformUsername}'
                      : 'Unknown',
                  style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.12),
                  border: Border.all(color: AppTheme.primary.withValues(alpha: 0.4)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  '🔥 ${metric.heatScore.toStringAsFixed(1)}',
                  style: const TextStyle(
                      color: AppTheme.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w700),
                ),
              ),
            ],
          ),
          if (metric.streamTitle != null) ...[
            const SizedBox(height: 8),
            Text(metric.streamTitle!,
                style: const TextStyle(
                    color: AppTheme.textPrimary, fontSize: 14),
                maxLines: 2,
                overflow: TextOverflow.ellipsis),
          ],
          if (metric.streamCategory != null) ...[
            const SizedBox(height: 4),
            Text(metric.streamCategory!,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 12)),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              const Icon(Icons.remove_red_eye_outlined,
                  size: 14, color: AppTheme.danger),
              const SizedBox(width: 4),
              Text(_fmtViewers(metric.liveViewerCount),
                  style: const TextStyle(
                      color: AppTheme.danger,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
              const SizedBox(width: 4),
              const Text('watching',
                  style: TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12)),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── Side drawer ──────────────────────────────────────────────────────────────

class _SideDrawer extends ConsumerWidget {
  const _SideDrawer();

  void _navTo(
    BuildContext context,
    WidgetRef ref,
    String path, {
    bool requiresAuth = false,
  }) {
    final isLoggedIn = ref.read(currentUserProvider) != null;
    Navigator.pop(context);
    if (requiresAuth && !isLoggedIn) {
      ref.read(pendingNavigationProvider.notifier).state = path;
      GoRouter.of(context).go('/login');
    } else {
      GoRouter.of(context).go(path);
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final profile = ref.watch(userProfileProvider).valueOrNull;
    final isLoggedIn = user != null;
    final isMarketMaker = profile?.isMarketMaker ?? false;
    final username = profile?.username ??
        profile?.displayName ??
        user?.email?.split('@')[0] ??
        'Guest';

    return Drawer(
      backgroundColor: const Color(0xFF12122A),
      child: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── Header ──────────────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
              decoration: const BoxDecoration(
                border: Border(bottom: BorderSide(color: AppTheme.cardBorder)),
              ),
              child: Row(
                children: [
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('N.O.R.A. Platforms',
                            style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.w800)),
                        Text('Phase 1',
                            style: TextStyle(
                                color: AppTheme.primary,
                                fontSize: 11,
                                fontWeight: FontWeight.w600)),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close,
                        color: AppTheme.textSecondary, size: 18),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),

            // ── User card ───────────────────────────────────────────────────
            GestureDetector(
              onTap: isLoggedIn
                  ? () => _navTo(context, ref, '/profile', requiresAuth: true)
                  : null,
              child: Container(
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.08),
                  border:
                      Border.all(color: AppTheme.primary.withValues(alpha: 0.2)),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 40, height: 40,
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: AppTheme.primary.withValues(alpha: 0.4)),
                      ),
                      child: Center(
                        child: isLoggedIn
                            ? Text(
                                username[0].toUpperCase(),
                                style: const TextStyle(
                                    color: AppTheme.primary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w700),
                              )
                            : const Icon(Icons.person_outline,
                                color: AppTheme.primary, size: 20),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            isLoggedIn ? username : 'Guest',
                            style: const TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w600),
                          ),
                          Text(
                            isLoggedIn
                                ? 'Tap to view profile'
                                : 'Sign in for full access',
                            style: const TextStyle(
                                color: AppTheme.textSecondary, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                    if (!isLoggedIn)
                      GestureDetector(
                        onTap: () {
                          Navigator.pop(context);
                          GoRouter.of(context).go('/login');
                        },
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 12, vertical: 6),
                          decoration: BoxDecoration(
                            color: AppTheme.primary,
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Text('Sign in →',
                              style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600)),
                        ),
                      ),
                  ],
                ),
              ),
            ),

            // ── NAVIGATE section ────────────────────────────────────────────
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
              child: Text(
                'NAVIGATE',
                style: TextStyle(
                    color: AppTheme.textSecondary.withValues(alpha: 0.6),
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1.2),
              ),
            ),

            Expanded(
              child: ListView(
                padding: const EdgeInsets.only(bottom: 8),
                children: [
                  _DrawerNavItem(
                    icon: Icons.bar_chart_outlined,
                    label: 'Dashboard',
                    subtitle: 'Market Maker hub',
                    badge: isMarketMaker ? 'MM Only' : null,
                    onTap: () =>
                        _navTo(context, ref, '/dashboard', requiresAuth: true),
                  ),
                  _DrawerNavItem(
                    icon: Icons.person_outline,
                    label: 'Profile',
                    subtitle: 'Your public profile',
                    onTap: () =>
                        _navTo(context, ref, '/profile', requiresAuth: true),
                  ),
                  _DrawerNavItem(
                    icon: Icons.receipt_long_outlined,
                    label: 'My Bets',
                    subtitle: 'Active & past bets',
                    onTap: () =>
                        _navTo(context, ref, '/mybets', requiresAuth: true),
                  ),
                  _DrawerNavItem(
                    icon: Icons.account_balance_wallet_outlined,
                    label: 'Wallet',
                    subtitle: 'Tokens & transactions',
                    onTap: () =>
                        _navTo(context, ref, '/wallet', requiresAuth: true),
                  ),
                  _DrawerNavItem(
                    icon: Icons.shield_outlined,
                    label: 'Arena',
                    subtitle: 'Competitive matches',
                    onTap: () =>
                        _navTo(context, ref, '/arena', requiresAuth: true),
                  ),
                  _DrawerNavItem(
                    icon: Icons.local_fire_department_outlined,
                    label: 'Hot Topic',
                    subtitle: 'Trending this week',
                    onTap: () => _navTo(context, ref, '/hot-topic'),
                  ),
                  _DrawerNavItem(
                    icon: Icons.emoji_events_outlined,
                    label: 'Challenges',
                    subtitle: 'Daily & weekly goals',
                    onTap: () => _navTo(context, ref, '/challenges',
                        requiresAuth: true),
                  ),

                  const SizedBox(height: 8),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 20),
                    child: Divider(color: AppTheme.cardBorder, height: 1),
                  ),
                  const SizedBox(height: 8),

                  // ── SUPPORT section ───────────────────────────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 6),
                    child: Text(
                      'SUPPORT',
                      style: TextStyle(
                          color: AppTheme.textSecondary.withValues(alpha: 0.6),
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.2),
                    ),
                  ),
                  _DrawerNavItem(
                    icon: Icons.settings_outlined,
                    label: 'Settings',
                    subtitle: 'App preferences',
                    onTap: () => Navigator.pop(context), // placeholder
                  ),
                  _DrawerNavItem(
                    icon: Icons.help_outline,
                    label: 'Help',
                    subtitle: 'Support & FAQ',
                    onTap: () => Navigator.pop(context), // placeholder
                  ),
                ],
              ),
            ),

            // ── Footer ──────────────────────────────────────────────────────
            Container(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
              decoration: const BoxDecoration(
                border: Border(top: BorderSide(color: AppTheme.cardBorder)),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('v1.0.0 — Phase 1',
                      style: TextStyle(
                          color: AppTheme.textSecondary, fontSize: 11)),
                  Text(
                    'NORA',
                    style: TextStyle(
                        color: AppTheme.primary.withValues(alpha: 0.6),
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.5),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DrawerNavItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String subtitle;
  final String? badge;
  final VoidCallback onTap;

  const _DrawerNavItem({
    required this.icon,
    required this.label,
    required this.subtitle,
    required this.onTap,
    this.badge,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Container(
        width: 36, height: 36,
        decoration: BoxDecoration(
          color: AppTheme.cardBorder,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: AppTheme.textSecondary, size: 18),
      ),
      title: Row(
        children: [
          Text(label,
              style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
          if (badge != null) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
              decoration: BoxDecoration(
                color: AppTheme.secondary.withValues(alpha: 0.12),
                border:
                    Border.all(color: AppTheme.secondary.withValues(alpha: 0.4)),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(badge!,
                  style: const TextStyle(
                      color: AppTheme.secondary,
                      fontSize: 9,
                      fontWeight: FontWeight.w700)),
            ),
          ],
        ],
      ),
      subtitle: Text(subtitle,
          style: const TextStyle(
              color: AppTheme.textSecondary, fontSize: 12)),
      onTap: onTap,
      dense: true,
      contentPadding:
          const EdgeInsets.symmetric(horizontal: 20, vertical: 2),
    );
  }
}

// ─── Notification sheet ───────────────────────────────────────────────────────

class _NotificationSheet extends ConsumerWidget {
  const _NotificationSheet();

  IconData _icon(String type) => switch (type) {
        'market_opened' => Icons.bar_chart_outlined,
        'bet_won' => Icons.emoji_events_outlined,
        'bet_lost' => Icons.sentiment_dissatisfied_outlined,
        'market_closing_soon' => Icons.timer_outlined,
        'referral_bonus' => Icons.people_outline,
        'token_earned' => Icons.toll_outlined,
        _ => Icons.notifications_outlined,
      };

  Color _color(String type) => switch (type) {
        'bet_won' || 'token_earned' || 'referral_bonus' => AppTheme.success,
        'bet_lost' => AppTheme.danger,
        'market_closing_soon' => const Color(0xFFFFD700),
        _ => AppTheme.primary,
      };

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final notificationsAsync = ref.watch(notificationsProvider);
    return DraggableScrollableSheet(
      initialChildSize: 0.6,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (context, sc) => Container(
        decoration: const BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
        ),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
              child: Column(
                children: [
                  Center(
                    child: Container(
                      width: 40, height: 4,
                      margin: const EdgeInsets.only(bottom: 16),
                      decoration: BoxDecoration(
                        color: AppTheme.cardBorder,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                  ),
                  const Text('Notifications',
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.bold)),
                ],
              ),
            ),
            const SizedBox(height: 8),
            const Divider(color: AppTheme.cardBorder, height: 1),
            Expanded(
              child: notificationsAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (_, __) => const Center(
                  child: Text('Could not load notifications',
                      style: TextStyle(color: AppTheme.textSecondary)),
                ),
                data: (notifications) {
                  if (notifications.isEmpty) {
                    return const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.notifications_off_outlined,
                              size: 48, color: AppTheme.textSecondary),
                          SizedBox(height: 16),
                          Text('No notifications yet',
                              style: TextStyle(
                                  color: AppTheme.textSecondary, fontSize: 15)),
                        ],
                      ),
                    );
                  }
                  return ListView.separated(
                    controller: sc,
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    itemCount: notifications.length,
                    separatorBuilder: (_, __) =>
                        const Divider(color: AppTheme.cardBorder, height: 1),
                    itemBuilder: (context, i) {
                      final n = notifications[i];
                      final color = _color(n.type);
                      return InkWell(
                        onTap: n.isRead
                            ? null
                            : () async {
                                await ref
                                    .read(notificationActionsProvider)
                                    .markRead(n.id);
                                ref.invalidate(notificationsProvider);
                              },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 20, vertical: 14),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Container(
                                width: 36, height: 36,
                                decoration: BoxDecoration(
                                  color: color.withValues(alpha: 0.12),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(_icon(n.type),
                                    color: color, size: 18),
                              ),
                              const SizedBox(width: 12),
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Expanded(
                                          child: Text(n.title,
                                              style: TextStyle(
                                                  color: AppTheme.textPrimary,
                                                  fontSize: 14,
                                                  fontWeight: n.isRead
                                                      ? FontWeight.normal
                                                      : FontWeight.w600)),
                                        ),
                                        if (!n.isRead)
                                          Container(
                                            width: 8, height: 8,
                                            margin: const EdgeInsets.only(left: 8),
                                            decoration: const BoxDecoration(
                                              color: AppTheme.primary,
                                              shape: BoxShape.circle,
                                            ),
                                          ),
                                      ],
                                    ),
                                    const SizedBox(height: 3),
                                    Text(n.body,
                                        style: const TextStyle(
                                            color: AppTheme.textSecondary,
                                            fontSize: 13,
                                            height: 1.4)),
                                    const SizedBox(height: 5),
                                    Text(timeago.format(n.createdAt),
                                        style: const TextStyle(
                                            color: AppTheme.textSecondary,
                                            fontSize: 11)),
                                  ],
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Divider / Footer ─────────────────────────────────────────────────────────

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) => Container(
        height: 1,
        margin: const EdgeInsets.fromLTRB(24, 0, 24, 32),
        color: AppTheme.cardBorder,
      );
}

class _FooterLinks extends StatelessWidget {
  const _FooterLinks();

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            GestureDetector(
              onTap: () => openUrlInBrowser('https://noraplatforms.com/privacy'),
              child: const Text('Privacy Policy',
                  style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                      decoration: TextDecoration.underline,
                      decorationColor: AppTheme.textSecondary)),
            ),
            const Text('  ·  ',
                style: TextStyle(
                    color: AppTheme.textSecondary, fontSize: 12)),
            GestureDetector(
              onTap: () => openUrlInBrowser('https://noraplatforms.com/terms'),
              child: const Text('Terms of Service',
                  style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                      decoration: TextDecoration.underline,
                      decorationColor: AppTheme.textSecondary)),
            ),
          ],
        ),
      );
}

// ─── Helpers ──────────────────────────────────────────────────────────────────

String _ordinal(int index) => switch (index) {
      0 => '1st',
      1 => '2nd',
      2 => '3rd',
      3 => '4th',
      _ => '${index + 1}th',
    };
