import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shimmer/shimmer.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/discover_providers.dart';

// ─────────────────────────────────────────────────────────────────────────────
// CONSTANTS
// ─────────────────────────────────────────────────────────────────────────────

const _kPlatformColors = {
  'YT': Color(0xFFFF4444),
  'TT': Color(0xFFEE1D52),
  'X': Color(0xFF8B8FA8),
  'Twitch': Color(0xFF9146FF),
  'Kick': Color(0xFF53FC18),
  'IG': Color(0xFFE1306C),
};

const _kTokenUpsell =
    'Your tokens mean more here — use them to discover the next big creator '
    'before everyone else does.';

// ─────────────────────────────────────────────────────────────────────────────
// HELPERS
// ─────────────────────────────────────────────────────────────────────────────

String _formatFollowers(int count) {
  if (count >= 1000000000) return '${(count / 1000000000).toStringAsFixed(1)}B';
  if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
  if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}K';
  return count.toString();
}

({String emoji, String label, Color color}) _tierInfo(String? tier) =>
    switch (tier) {
      'on_fire' => (
          emoji: '🔥',
          label: 'On Fire',
          color: const Color(0xFFFF6B35),
        ),
      'rising' => (
          emoji: '⚡',
          label: 'Rising',
          color: const Color(0xFFFFD700),
        ),
      'watched' => (
          emoji: '👀',
          label: 'Watched',
          color: AppTheme.primary,
        ),
      _ => (
          emoji: '',
          label: 'Listed',
          color: AppTheme.textSecondary,
        ),
    };

// ─────────────────────────────────────────────────────────────────────────────
// SCREEN
// ─────────────────────────────────────────────────────────────────────────────

class DiscoverScreen extends ConsumerStatefulWidget {
  const DiscoverScreen({super.key});

  @override
  ConsumerState<DiscoverScreen> createState() => _DiscoverScreenState();
}

class _DiscoverScreenState extends ConsumerState<DiscoverScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
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
        title: const Text('Discover'),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppTheme.primary,
          indicatorWeight: 2,
          labelColor: AppTheme.primary,
          unselectedLabelColor: AppTheme.textSecondary,
          labelStyle: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.3,
          ),
          tabs: const [
            Tab(text: 'Famous'),
            Tab(text: 'Rising'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          _FamousTab(),
          _RisingTab(),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TAB 1 — FAMOUS
// ─────────────────────────────────────────────────────────────────────────────

class _FamousTab extends ConsumerWidget {
  const _FamousTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final creatorsAsync = ref.watch(famousCreatorsProvider);
    return creatorsAsync.when(
      loading: () => const _ShimmerList(),
      error: (_, __) => _ErrorState(
        onRetry: () => ref.invalidate(famousCreatorsProvider),
      ),
      data: (creators) {
        if (creators.isEmpty) {
          return const _EmptyState(message: 'No famous creators yet.');
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          itemCount: creators.length,
          itemBuilder: (context, i) => _FamousCreatorCard(creator: creators[i]),
        );
      },
    );
  }
}

class _FamousCreatorCard extends StatelessWidget {
  final FamousCreator creator;
  const _FamousCreatorCard({required this.creator});

  void _openSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _FamousCreatorSheet(creator: creator),
    );
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => _openSheet(context),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              _LetterAvatar(label: creator.name, size: 48),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      creator.name,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontWeight: FontWeight.w700,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      children: creator.activePlatforms
                          .map((p) => _PlatformChip(label: p.label))
                          .toList(),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    _formatFollowers(creator.totalFollowers),
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontWeight: FontWeight.w700,
                      fontSize: 15,
                    ),
                  ),
                  const SizedBox(height: 2),
                  const Text(
                    'followers',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FAMOUS CREATOR BOTTOM SHEET
// ─────────────────────────────────────────────────────────────────────────────

class _FamousCreatorSheet extends StatelessWidget {
  final FamousCreator creator;
  const _FamousCreatorSheet({required this.creator});

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.65,
      minChildSize: 0.4,
      maxChildSize: 0.92,
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: SingleChildScrollView(
            controller: scrollController,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Drag handle
                Center(
                  child: Container(
                    margin: const EdgeInsets.only(top: 12, bottom: 24),
                    width: 40,
                    height: 4,
                    decoration: BoxDecoration(
                      color: AppTheme.cardBorder,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),

                // Avatar + name
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    children: [
                      _LetterAvatar(label: creator.name, size: 64),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              creator.name,
                              style: const TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 22,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '${_formatFollowers(creator.totalFollowers)} followers',
                              style: const TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // Bio
                if (creator.bio != null) ...[
                  const SizedBox(height: 20),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      creator.bio!,
                      style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 14,
                        height: 1.5,
                      ),
                    ),
                  ),
                ],

                // Platforms
                if (creator.activePlatforms.isNotEmpty) ...[
                  const SizedBox(height: 24),
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      'Platforms',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  ...creator.activePlatforms.map(
                    (p) => Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 5),
                      child: Row(
                        children: [
                          _PlatformChip(label: p.label),
                          const SizedBox(width: 12),
                          Text(
                            p.handle,
                            style: const TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 14,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],

                // Token upsell
                const SizedBox(height: 28),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 40),
                  child: Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [
                          Color(0x266C63FF), // primary @ 15%
                          Color(0x1A9C27B0), // purple @ 10%
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(14),
                      border: const Border.fromBorderSide(BorderSide(
                        color: Color(0x4D6C63FF), // primary @ 30%
                      )),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('💡', style: TextStyle(fontSize: 18)),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _kTokenUpsell,
                            style: TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 14,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TAB 2 — RISING
// ─────────────────────────────────────────────────────────────────────────────

class _RisingTab extends ConsumerWidget {
  const _RisingTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final creatorsAsync = ref.watch(risingCreatorsProvider);
    return creatorsAsync.when(
      loading: () => const _ShimmerList(),
      error: (_, __) => _ErrorState(
        onRetry: () => ref.invalidate(risingCreatorsProvider),
      ),
      data: (creators) {
        if (creators.isEmpty) {
          return const _EmptyState(
            message:
                'No rising creators yet — be the first to claim your spot.',
            icon: Icons.rocket_launch_outlined,
          );
        }
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
          itemCount: creators.length,
          itemBuilder: (context, i) =>
              _RisingCreatorCard(creator: creators[i]),
        );
      },
    );
  }
}

class _RisingCreatorCard extends StatelessWidget {
  final RisingCreator creator;
  const _RisingCreatorCard({required this.creator});

  @override
  Widget build(BuildContext context) {
    final tier = _tierInfo(creator.spotlightTier);
    final hasTier = creator.spotlightTier != null &&
        creator.spotlightTier != 'listed';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            // Avatar
            _CreatorAvatar(creator: creator, size: 48),
            const SizedBox(width: 14),

            // Name + tokens
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          creator.displayLabel,
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      if (hasTier) ...[
                        const SizedBox(width: 8),
                        _TierBadge(tier: tier),
                      ],
                    ],
                  ),
                  const SizedBox(height: 5),
                  Row(
                    children: [
                      const Text(
                        '🪙',
                        style: TextStyle(fontSize: 12),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        '${creator.availableTokens} tokens',
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            // Bet button
            const SizedBox(width: 10),
            _BetButton(creatorName: creator.displayLabel),
          ],
        ),
      ),
    );
  }
}

class _BetButton extends StatelessWidget {
  final String creatorName;
  const _BetButton({required this.creatorName});

  @override
  Widget build(BuildContext context) {
    return OutlinedButton(
      onPressed: () {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Betting on $creatorName coming soon'),
            backgroundColor: AppTheme.surface,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
              side: const BorderSide(color: AppTheme.cardBorder),
            ),
          ),
        );
      },
      style: OutlinedButton.styleFrom(
        foregroundColor: AppTheme.primary,
        side: const BorderSide(color: AppTheme.primary),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
        ),
        minimumSize: const Size(0, 36),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
      child: const Text('Bet'),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHARED WIDGETS
// ─────────────────────────────────────────────────────────────────────────────

class _LetterAvatar extends StatelessWidget {
  final String label;
  final double size;
  const _LetterAvatar({required this.label, required this.size});

  // Derive a consistent accent color from the creator name so each avatar
  // has a distinct but stable color without needing a real image.
  Color _avatarColor() {
    const palette = [
      Color(0xFF6C63FF),
      Color(0xFF00C896),
      Color(0xFFFF6B35),
      Color(0xFFEE1D52),
      Color(0xFF9146FF),
      Color(0xFFFFD700),
      Color(0xFF00BCD4),
    ];
    final index = label.codeUnits.fold(0, (sum, c) => sum + c) % palette.length;
    return palette[index];
  }

  @override
  Widget build(BuildContext context) {
    final color = _avatarColor();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        shape: BoxShape.circle,
        border: Border.all(color: color.withValues(alpha: 0.4), width: 1.5),
      ),
      child: Center(
        child: Text(
          label.isNotEmpty ? label[0].toUpperCase() : '?',
          style: TextStyle(
            color: color,
            fontWeight: FontWeight.bold,
            fontSize: size * 0.38,
          ),
        ),
      ),
    );
  }
}

class _CreatorAvatar extends StatelessWidget {
  final RisingCreator creator;
  final double size;
  const _CreatorAvatar({required this.creator, required this.size});

  @override
  Widget build(BuildContext context) {
    if (creator.avatarUrl != null) {
      return ClipOval(
        child: CachedNetworkImage(
          imageUrl: creator.avatarUrl!,
          width: size,
          height: size,
          fit: BoxFit.cover,
          errorWidget: (_, __, ___) =>
              _LetterAvatar(label: creator.displayLabel, size: size),
          placeholder: (_, __) =>
              _LetterAvatar(label: creator.displayLabel, size: size),
        ),
      );
    }
    return _LetterAvatar(label: creator.displayLabel, size: size);
  }
}

class _PlatformChip extends StatelessWidget {
  final String label;
  const _PlatformChip({required this.label});

  @override
  Widget build(BuildContext context) {
    final color = _kPlatformColors[label] ?? AppTheme.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.2,
        ),
      ),
    );
  }
}

class _TierBadge extends StatelessWidget {
  final ({String emoji, String label, Color color}) tier;
  const _TierBadge({required this.tier});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: tier.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: tier.color.withValues(alpha: 0.35)),
      ),
      child: Text(
        '${tier.emoji} ${tier.label}',
        style: TextStyle(
          color: tier.color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// LOADING / EMPTY / ERROR STATES
// ─────────────────────────────────────────────────────────────────────────────

class _ShimmerList extends StatelessWidget {
  const _ShimmerList();

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AppTheme.surface,
      highlightColor: AppTheme.cardBorder,
      child: ListView.builder(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        itemCount: 6,
        itemBuilder: (_, __) => Container(
          margin: const EdgeInsets.only(bottom: 12),
          height: 80,
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String message;
  final IconData icon;
  const _EmptyState({
    required this.message,
    this.icon = Icons.explore_outlined,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: AppTheme.textSecondary),
            const SizedBox(height: 16),
            Text(
              message,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 15,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorState({required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off_rounded,
                size: 56, color: AppTheme.textSecondary),
            const SizedBox(height: 16),
            const Text(
              'Could not load creators.\nCheck your connection and try again.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 15,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
            TextButton(
              onPressed: onRetry,
              child: const Text(
                'Retry',
                style: TextStyle(
                  color: AppTheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
