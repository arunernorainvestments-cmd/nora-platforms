import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shimmer/shimmer.dart';
import 'package:timeago/timeago.dart' as timeago;
import '../../../core/theme/app_theme.dart';
import '../../auth/providers/auth_provider.dart';
import '../../notifications/providers/notification_providers.dart';
import '../providers/home_providers.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final unreadCount = ref.watch(unreadCountProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('N.O.R.A. Platforms'),
        actions: [
          IconButton(
            tooltip: 'Notifications',
            icon: Stack(
              clipBehavior: Clip.none,
              children: [
                const Icon(Icons.notifications_outlined),
                if (unreadCount > 0)
                  Positioned(
                    right: -3,
                    top: -3,
                    child: Container(
                      padding: const EdgeInsets.all(2),
                      decoration: const BoxDecoration(
                        color: AppTheme.danger,
                        shape: BoxShape.circle,
                      ),
                      constraints:
                          const BoxConstraints(minWidth: 16, minHeight: 16),
                      child: Text(
                        unreadCount > 99 ? '99+' : '$unreadCount',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  ),
              ],
            ),
            onPressed: () => showModalBottomSheet(
              context: context,
              isScrollControlled: true,
              backgroundColor: Colors.transparent,
              builder: (_) => const _NotificationSheet(),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        color: AppTheme.primary,
        backgroundColor: AppTheme.surface,
        onRefresh: () async {
          ref.invalidate(homeTokenBalanceProvider);
          ref.invalidate(spotlightCreatorsProvider);
          ref.invalidate(homeFamousCreatorsProvider);
        },
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
          children: const [
            _WelcomeCard(),
            SizedBox(height: 28),
            _SpotlightSection(),
            SizedBox(height: 28),
            _FamousCarouselSection(),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// WELCOME CARD
// ─────────────────────────────────────────────────────────────────────────────

class _WelcomeCard extends ConsumerWidget {
  const _WelcomeCard();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    final balanceAsync = ref.watch(homeTokenBalanceProvider);

    final displayName = user?.email?.split('@')[0] ?? 'Trader';

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(22),
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
          Text(
            'Welcome back,',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.8),
              fontSize: 14,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            displayName,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: [
              _WelcomeStat(
                label: 'Tokens',
                valueWidget: balanceAsync.when(
                  loading: () => const _InlineShimmer(width: 48, height: 20),
                  error: (_, __) => const Text(
                    '—',
                    style: TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                  data: (b) => Text(
                    '${b.availableTokens}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                      fontSize: 18,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              const _WelcomeStat(
                label: 'Active Bets',
                valueWidget: Text(
                  '0',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 18,
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _WelcomeStat extends StatelessWidget {
  final String label;
  final Widget valueWidget;
  const _WelcomeStat({required this.label, required this.valueWidget});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.18),
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
          const SizedBox(height: 2),
          valueWidget,
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SPOTLIGHT SECTION
// ─────────────────────────────────────────────────────────────────────────────

class _SpotlightSection extends ConsumerWidget {
  const _SpotlightSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final creatorsAsync = ref.watch(spotlightCreatorsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          title: '🔥 Spotlight',
          subtitle: 'Top creators right now',
        ),
        const SizedBox(height: 12),
        creatorsAsync.when(
          loading: () => const _SpotlightShimmer(),
          error: (_, __) => const _SpotlightEmpty(),
          data: (creators) {
            if (creators.isEmpty) return const _SpotlightEmpty();
            return Column(
              children: creators
                  .map((c) => _SpotlightCreatorCard(creator: c))
                  .toList(),
            );
          },
        ),
      ],
    );
  }
}

class _SpotlightCreatorCard extends StatelessWidget {
  final SpotlightCreator creator;
  const _SpotlightCreatorCard({required this.creator});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: const Color(0xFF3A2A4E)),
      ),
      child: Row(
        children: [
          // Avatar
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.15),
              shape: BoxShape.circle,
              border: Border.all(
                color: AppTheme.primary.withValues(alpha: 0.4),
                width: 1.5,
              ),
            ),
            child: Center(
              child: Text(
                creator.initials,
                style: const TextStyle(
                  color: AppTheme.primary,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Name + score
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  creator.displayLabel,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 3),
                Text(
                  'Score: ${creator.score.toStringAsFixed(1)}',
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),

          // Tier badge
          _TierBadge(tier: creator.tier),
        ],
      ),
    );
  }
}

class _SpotlightEmpty extends StatelessWidget {
  const _SpotlightEmpty();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 20),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: const Column(
        children: [
          Text('🔥', style: TextStyle(fontSize: 32)),
          SizedBox(height: 10),
          Text(
            'No spotlight creators yet — start betting to crown the first',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 14,
              height: 1.4,
            ),
          ),
        ],
      ),
    );
  }
}

class _SpotlightShimmer extends StatelessWidget {
  const _SpotlightShimmer();

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AppTheme.surface,
      highlightColor: AppTheme.cardBorder,
      child: Column(
        children: List.generate(
          3,
          (_) => Container(
            margin: const EdgeInsets.only(bottom: 10),
            height: 72,
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FAMOUS CREATORS CAROUSEL
// ─────────────────────────────────────────────────────────────────────────────

class _FamousCarouselSection extends ConsumerWidget {
  const _FamousCarouselSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final creatorsAsync = ref.watch(homeFamousCreatorsProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionHeader(
          title: 'Famous Creators',
          subtitle: 'Explore — no betting on these',
        ),
        const SizedBox(height: 12),
        SizedBox(
          height: 130,
          child: creatorsAsync.when(
            loading: () => const _CarouselShimmer(),
            error: (_, __) => const _CarouselError(),
            data: (creators) {
              if (creators.isEmpty) {
                return const Center(
                  child: Text(
                    'No creators found',
                    style: TextStyle(color: AppTheme.textSecondary),
                  ),
                );
              }
              return ListView.builder(
                scrollDirection: Axis.horizontal,
                itemCount: creators.length,
                itemBuilder: (context, i) =>
                    _FamousCreatorTile(creator: creators[i]),
              );
            },
          ),
        ),
      ],
    );
  }
}

class _FamousCreatorTile extends StatelessWidget {
  final HomeFamousCreator creator;
  const _FamousCreatorTile({required this.creator});

  String _formatFollowers(int count) {
    if (count >= 1000000000) return '${(count / 1000000000).toStringAsFixed(1)}B';
    if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}K';
    return count.toString();
  }

  Color _avatarColor() {
    const palette = [
      Color(0xFF6C63FF), Color(0xFF00C896), Color(0xFFFF6B35),
      Color(0xFFEE1D52), Color(0xFF9146FF), Color(0xFFFFD700),
      Color(0xFF00BCD4),
    ];
    final index =
        creator.name.codeUnits.fold(0, (sum, c) => sum + c) % palette.length;
    return palette[index];
  }

  @override
  Widget build(BuildContext context) {
    final color = _avatarColor();
    return Container(
      width: 110,
      margin: const EdgeInsets.only(right: 12),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          // Avatar
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              shape: BoxShape.circle,
              border: Border.all(color: color.withValues(alpha: 0.4), width: 1.5),
            ),
            child: Center(
              child: Text(
                creator.name[0].toUpperCase(),
                style: TextStyle(
                  color: color,
                  fontWeight: FontWeight.bold,
                  fontSize: 18,
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          // Name
          Text(
            creator.name,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontWeight: FontWeight.w600,
              fontSize: 12,
            ),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 3),
          // Followers
          Text(
            _formatFollowers(creator.totalFollowers),
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 3),
          // Platform count
          Text(
            '${creator.platformCount} platform${creator.platformCount == 1 ? '' : 's'}',
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 10,
            ),
          ),
        ],
      ),
    );
  }
}

class _CarouselShimmer extends StatelessWidget {
  const _CarouselShimmer();

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: AppTheme.surface,
      highlightColor: AppTheme.cardBorder,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: 5,
        itemBuilder: (_, __) => Container(
          width: 110,
          margin: const EdgeInsets.only(right: 12),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(14),
          ),
        ),
      ),
    );
  }
}

class _CarouselError extends StatelessWidget {
  const _CarouselError();

  @override
  Widget build(BuildContext context) {
    return const Center(
      child: Text(
        'Could not load creators',
        style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHARED WIDGETS
// ─────────────────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  final String subtitle;
  const _SectionHeader({required this.title, required this.subtitle});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 17,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          subtitle,
          style: const TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

class _TierBadge extends StatelessWidget {
  final String tier;
  const _TierBadge({required this.tier});

  ({String emoji, String label, Color color}) get _info => switch (tier) {
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

  @override
  Widget build(BuildContext context) {
    final info = _info;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: info.color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: info.color.withValues(alpha: 0.35)),
      ),
      child: Text(
        '${info.emoji} ${info.label}'.trim(),
        style: TextStyle(
          color: info.color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _InlineShimmer extends StatelessWidget {
  final double width;
  final double height;
  const _InlineShimmer({required this.width, required this.height});

  @override
  Widget build(BuildContext context) {
    return Shimmer.fromColors(
      baseColor: Colors.white.withValues(alpha: 0.15),
      highlightColor: Colors.white.withValues(alpha: 0.35),
      child: Container(
        width: width,
        height: height,
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(4),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// NOTIFICATION SHEET
// ─────────────────────────────────────────────────────────────────────────────

class _NotificationSheet extends ConsumerWidget {
  const _NotificationSheet();

  IconData _iconForType(String type) => switch (type) {
        'market_opened' => Icons.bar_chart_outlined,
        'bet_won' => Icons.emoji_events_outlined,
        'bet_lost' => Icons.sentiment_dissatisfied_outlined,
        'market_closing_soon' => Icons.timer_outlined,
        'referral_bonus' => Icons.people_outline,
        'token_earned' => Icons.toll_outlined,
        _ => Icons.notifications_outlined,
      };

  Color _colorForType(String type) => switch (type) {
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
      builder: (context, scrollController) {
        return Container(
          decoration: const BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
          ),
          child: Column(
            children: [
              // Drag handle + header
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                child: Column(
                  children: [
                    Center(
                      child: Container(
                        width: 40,
                        height: 4,
                        margin: const EdgeInsets.only(bottom: 16),
                        decoration: BoxDecoration(
                          color: AppTheme.cardBorder,
                          borderRadius: BorderRadius.circular(2),
                        ),
                      ),
                    ),
                    const Text(
                      'Notifications',
                      style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              const Divider(color: AppTheme.cardBorder, height: 1),
              Expanded(
                child: notificationsAsync.when(
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
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
                            Text(
                              'No notifications yet',
                              style: TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 15,
                              ),
                            ),
                          ],
                        ),
                      );
                    }
                    return ListView.separated(
                      controller: scrollController,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      itemCount: notifications.length,
                      separatorBuilder: (_, __) =>
                          const Divider(color: AppTheme.cardBorder, height: 1),
                      itemBuilder: (context, i) {
                        final n = notifications[i];
                        final color = _colorForType(n.type);
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
                                // Type icon
                                Container(
                                  width: 36,
                                  height: 36,
                                  decoration: BoxDecoration(
                                    color: color.withValues(alpha: 0.12),
                                    shape: BoxShape.circle,
                                  ),
                                  child: Icon(_iconForType(n.type),
                                      color: color, size: 18),
                                ),
                                const SizedBox(width: 12),
                                // Title + body + time
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Expanded(
                                            child: Text(
                                              n.title,
                                              style: TextStyle(
                                                color: AppTheme.textPrimary,
                                                fontSize: 14,
                                                fontWeight: n.isRead
                                                    ? FontWeight.normal
                                                    : FontWeight.w600,
                                              ),
                                            ),
                                          ),
                                          if (!n.isRead)
                                            Container(
                                              width: 8,
                                              height: 8,
                                              margin: const EdgeInsets.only(
                                                  left: 8),
                                              decoration: const BoxDecoration(
                                                color: AppTheme.primary,
                                                shape: BoxShape.circle,
                                              ),
                                            ),
                                        ],
                                      ),
                                      const SizedBox(height: 3),
                                      Text(
                                        n.body,
                                        style: const TextStyle(
                                          color: AppTheme.textSecondary,
                                          fontSize: 13,
                                          height: 1.4,
                                        ),
                                      ),
                                      const SizedBox(height: 5),
                                      Text(
                                        timeago.format(n.createdAt),
                                        style: const TextStyle(
                                          color: AppTheme.textSecondary,
                                          fontSize: 11,
                                        ),
                                      ),
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
        );
      },
    );
  }
}
