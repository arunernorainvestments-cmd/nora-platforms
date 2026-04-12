import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../markets/widgets/bet_bottom_sheet.dart';
import '../models/platform_connection.dart';
import '../models/platform_metric.dart';
import '../models/public_profile_data.dart';
import '../providers/public_profile_providers.dart';

// ─────────────────────────────────────────────────────────────────────────────
// SCREEN
// ─────────────────────────────────────────────────────────────────────────────

class PublicProfileScreen extends ConsumerWidget {
  final String username;
  const PublicProfileScreen({super.key, required this.username});

  void _copyShareLink(BuildContext context) {
    const base = 'https://nora-platforms.vercel.app/u/';
    Clipboard.setData(ClipboardData(text: '$base$username'));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Link copied to clipboard'),
        backgroundColor: AppTheme.surface,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: AppTheme.cardBorder),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(publicProfileProvider(username));

    return Scaffold(
      appBar: AppBar(
        title: Text('@$username'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: 'Copy profile link',
            onPressed: () => _copyShareLink(context),
          ),
        ],
      ),
      body: profileAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) => _ErrorState(
          onRetry: () => ref.invalidate(publicProfileProvider(username)),
        ),
        data: (profile) {
          if (profile == null) return const _NotFoundState();
          return _ProfileBody(
            profile: profile,
            onRefresh: () => ref.invalidate(publicProfileProvider(username)),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BODY
// ─────────────────────────────────────────────────────────────────────────────

class _ProfileBody extends StatelessWidget {
  final PublicProfileData profile;
  final VoidCallback onRefresh;

  const _ProfileBody({required this.profile, required this.onRefresh});

  @override
  Widget build(BuildContext context) {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    final isOwnProfile = currentUserId != null && currentUserId == profile.id;

    final liveMetrics =
        profile.metrics.where((m) => m.isLive).toList();

    final double maxHeatScore = profile.metrics.isEmpty
        ? 0.0
        : profile.metrics
            .map((m) => m.heatScore)
            .reduce((a, b) => a > b ? a : b);

    // Platform Stats: only platforms present in BOTH connections and metrics
    final connectedPlatforms =
        profile.connections.map((c) => c.platform).toSet();
    final statsMetrics = profile.metrics
        .where((m) => connectedPlatforms.contains(m.platform))
        .toList();

    return CustomScrollView(
      slivers: [
        // ── A) Header ───────────────────────────────────────────────────────
        SliverToBoxAdapter(
          child: _HeaderSection(
            profile: profile,
            heatScore: maxHeatScore,
          ),
        ),

        // ── B) Action buttons ────────────────────────────────────────────────
        if (profile.isMarketMaker && profile.connections.isNotEmpty)
          SliverToBoxAdapter(
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 4),
              child: _ActionSection(
                profile: profile,
                isOwnProfile: isOwnProfile,
                onRefresh: onRefresh,
              ),
            ),
          ),

        // ── C) Live Now ──────────────────────────────────────────────────────
        if (liveMetrics.isNotEmpty)
          SliverToBoxAdapter(
            child: _LiveNowSection(
              liveMetrics: liveMetrics,
              connections: profile.connections,
            ),
          ),

        // ── D) Platform Stats ────────────────────────────────────────────────
        if (profile.connections.isNotEmpty)
          SliverToBoxAdapter(
            child: _PlatformStatsSection(
              metrics: statsMetrics,
              connections: profile.connections,
              isMarketMaker: profile.isMarketMaker,
            ),
          ),

        // ── E) Recent Content ────────────────────────────────────────────────
        const SliverToBoxAdapter(child: _RecentContentSection()),

        const SliverToBoxAdapter(child: SizedBox(height: 48)),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// A) HEADER
// ─────────────────────────────────────────────────────────────────────────────

class _HeaderSection extends StatelessWidget {
  final PublicProfileData profile;
  final double heatScore;

  const _HeaderSection({required this.profile, required this.heatScore});

  @override
  Widget build(BuildContext context) {
    final letter = profile.username.isNotEmpty
        ? profile.username[0].toUpperCase()
        : '?';

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 24, 20, 16),
      child: Column(
        children: [
          // Avatar
          Container(
            width: 64,
            height: 64,
            decoration: const BoxDecoration(
              color: AppTheme.primary,
              shape: BoxShape.circle,
            ),
            child: Center(
              child: Text(
                letter,
                style: const TextStyle(
                  fontSize: 28,
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Username
          Text(
            '@${profile.username}',
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),

          // Bio
          if (profile.bio != null && profile.bio!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              profile.bio!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 14,
                height: 1.5,
              ),
            ),
          ],

          // Category chips
          if (profile.category1 != null || profile.category2 != null) ...[
            const SizedBox(height: 10),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (profile.category1 != null)
                  _CategoryPill(label: profile.category1!),
                if (profile.category1 != null && profile.category2 != null)
                  const SizedBox(width: 8),
                if (profile.category2 != null)
                  _CategoryPill(label: profile.category2!),
              ],
            ),
          ],

          // Heat Score — show whenever platforms are connected
          if (profile.connections.isNotEmpty) ...[
            const SizedBox(height: 20),
            _HeatScoreDisplay(
              value: profile.isMarketMaker
                  ? heatScore.toStringAsFixed(1)
                  : '---',
            ),
          ],
        ],
      ),
    );
  }
}

class _HeatScoreDisplay extends StatelessWidget {
  final String value;
  const _HeatScoreDisplay({required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('🔥', style: TextStyle(fontSize: 22)),
              const SizedBox(width: 8),
              Text(
                value,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 30,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          const Text(
            'Heat Score',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

class _CategoryPill extends StatelessWidget {
  final String label;
  const _CategoryPill({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: AppTheme.primary,
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// B) ACTION BUTTONS
// ─────────────────────────────────────────────────────────────────────────────

class _ActionSection extends StatelessWidget {
  final PublicProfileData profile;
  final bool isOwnProfile;
  final VoidCallback onRefresh;

  const _ActionSection({
    required this.profile,
    required this.isOwnProfile,
    required this.onRefresh,
  });

  void _showPromoteSnackbar(BuildContext context) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Promotions coming soon!'),
        backgroundColor: AppTheme.surface,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: AppTheme.cardBorder),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final promoteButton = OutlinedButton(
      onPressed: () => _showPromoteSnackbar(context),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppTheme.primary,
        side: const BorderSide(color: AppTheme.primary),
        minimumSize: const Size(double.infinity, 48),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: const Text('Promote'),
    );

    if (isOwnProfile) {
      return promoteButton;
    }

    return Row(
      children: [
        Expanded(
          child: ElevatedButton(
            onPressed: () {
              final currentUser = Supabase.instance.client.auth.currentUser;
              if (currentUser == null) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: const Text('Sign in to place a bet'),
                    backgroundColor: AppTheme.surface,
                    behavior: SnackBarBehavior.floating,
                    action: SnackBarAction(
                      label: 'Sign In',
                      textColor: AppTheme.primary,
                      onPressed: () => context.go('/login'),
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                      side: const BorderSide(color: AppTheme.cardBorder),
                    ),
                  ),
                );
                return;
              }
              showBetBottomSheet(
                context,
                creatorId: profile.id,
                creatorUsername: profile.username,
                onBetPlaced: onRefresh,
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              minimumSize: const Size(double.infinity, 48),
              shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12)),
            ),
            child: const Text('Bet'),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(child: promoteButton),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// C) LIVE NOW
// ─────────────────────────────────────────────────────────────────────────────

class _LiveNowSection extends StatelessWidget {
  final List<PlatformMetric> liveMetrics;
  final List<PlatformConnection> connections;

  const _LiveNowSection({
    required this.liveMetrics,
    required this.connections,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader('🔴 Live Now'),
          const SizedBox(height: 12),
          ...liveMetrics.map((m) {
            final matches =
                connections.where((c) => c.platform == m.platform);
            final conn = matches.isNotEmpty ? matches.first : null;
            return _LiveCard(
              metric: m,
              platformUsername: conn?.platformUsername,
            );
          }),
        ],
      ),
    );
  }
}

class _LiveCard extends StatelessWidget {
  final PlatformMetric metric;
  final String? platformUsername;

  const _LiveCard({required this.metric, this.platformUsername});

  // Brand colors — only permitted hardcoded hex values
  static const _brandColors = {
    'twitch': Color(0xFF9146FF),
    'youtube': Color(0xFFFF0000),
  };
  static const _platformLabels = {
    'twitch': 'Twitch',
    'youtube': 'YouTube',
  };

  String _formatCount(int count) {
    if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}K';
    return count.toString();
  }

  @override
  Widget build(BuildContext context) {
    final color =
        _brandColors[metric.platform] ?? AppTheme.textSecondary;
    final label =
        _platformLabels[metric.platform] ?? metric.platform;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Row(
        children: [
          // Platform label
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          const SizedBox(width: 10),

          // LIVE badge
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppTheme.danger.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                  color: AppTheme.danger.withValues(alpha: 0.4)),
            ),
            child: const Text(
              'LIVE',
              style: TextStyle(
                color: AppTheme.danger,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),

          // Platform username
          if (platformUsername != null) ...[
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '@$platformUsername',
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 13,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ] else
            const Spacer(),

          // Viewer count
          if (metric.liveViewerCount > 0) ...[
            const Icon(Icons.visibility_outlined,
                size: 14, color: AppTheme.textSecondary),
            const SizedBox(width: 4),
            Text(
              _formatCount(metric.liveViewerCount),
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 12),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// D) PLATFORM STATS
// ─────────────────────────────────────────────────────────────────────────────

class _PlatformStatsSection extends StatelessWidget {
  final List<PlatformMetric> metrics;
  final List<PlatformConnection> connections;
  final bool isMarketMaker;

  const _PlatformStatsSection({
    required this.metrics,
    required this.connections,
    required this.isMarketMaker,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader('Platform Stats'),
          const SizedBox(height: 12),
          if (isMarketMaker)
            ...metrics.map((m) {
              final matches =
                  connections.where((c) => c.platform == m.platform);
              final conn = matches.isNotEmpty ? matches.first : null;
              return _PlatformStatCard(
                metric: m,
                platformUsername: conn?.platformUsername,
              );
            })
          else
            ...connections.map((c) => _RedactedStatCard(connection: c)),
        ],
      ),
    );
  }
}

class _PlatformStatCard extends StatelessWidget {
  final PlatformMetric metric;
  final String? platformUsername;

  const _PlatformStatCard({required this.metric, this.platformUsername});

  static const _brandColors = {
    'twitch': Color(0xFF9146FF),
    'youtube': Color(0xFFFF0000),
  };
  static const _platformLabels = {
    'twitch': 'Twitch',
    'youtube': 'YouTube',
  };

  String _formatCount(int count) {
    if (count >= 1000000) return '${(count / 1000000).toStringAsFixed(1)}M';
    if (count >= 1000) return '${(count / 1000).toStringAsFixed(1)}K';
    return count.toString();
  }

  @override
  Widget build(BuildContext context) {
    final color =
        _brandColors[metric.platform] ?? AppTheme.textSecondary;
    final label =
        _platformLabels[metric.platform] ?? metric.platform;
    final followerLabel =
        metric.platform == 'youtube' ? 'Subscribers' : 'Followers';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Platform header row
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border:
                      Border.all(color: color.withValues(alpha: 0.4)),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (platformUsername != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '@$platformUsername',
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 13,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
              if (metric.isLive) ...[
                const Spacer(),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppTheme.danger.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                        color: AppTheme.danger.withValues(alpha: 0.4)),
                  ),
                  child: const Text(
                    'LIVE',
                    style: TextStyle(
                      color: AppTheme.danger,
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),

          // Stats grid
          Wrap(
            spacing: 20,
            runSpacing: 10,
            children: [
              _StatItem(
                  label: followerLabel,
                  value: _formatCount(metric.followerCount)),
              if (metric.isLive)
                _StatItem(
                    label: 'Viewers',
                    value: _formatCount(metric.liveViewerCount)),
              _StatItem(
                  label: 'Raw Score',
                  value: metric.displayScore.toStringAsFixed(1)),
              _StatItem(
                  label: 'Heat Score',
                  value: metric.heatScore.toStringAsFixed(1)),
            ],
          ),
        ],
      ),
    );
  }
}

class _RedactedStatCard extends StatelessWidget {
  final PlatformConnection connection;
  const _RedactedStatCard({required this.connection});

  static const _brandColors = {
    'twitch': Color(0xFF9146FF),
    'youtube': Color(0xFFFF0000),
  };
  static const _platformLabels = {
    'twitch': 'Twitch',
    'youtube': 'YouTube',
  };

  @override
  Widget build(BuildContext context) {
    final color =
        _brandColors[connection.platform] ?? AppTheme.textSecondary;
    final label =
        _platformLabels[connection.platform] ?? connection.platform;
    final followerLabel =
        connection.platform == 'youtube' ? 'Subscribers' : 'Followers';

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border:
                      Border.all(color: color.withValues(alpha: 0.4)),
                ),
                child: Text(
                  label,
                  style: TextStyle(
                    color: color,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              if (connection.platformUsername != null) ...[
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    '@${connection.platformUsername}',
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 13,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ],
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 20,
            runSpacing: 10,
            children: [
              _StatItem(label: followerLabel, value: '---'),
              const _StatItem(label: 'Raw Score', value: '---'),
              const _StatItem(label: 'Heat Score', value: '---'),
            ],
          ),
        ],
      ),
    );
  }
}

class _StatItem extends StatelessWidget {
  final String label;
  final String value;
  const _StatItem({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          value,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.bold,
          ),
        ),
        Text(
          label,
          style: const TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 11,
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// E) RECENT CONTENT (placeholder)
// ─────────────────────────────────────────────────────────────────────────────

class _RecentContentSection extends StatelessWidget {
  const _RecentContentSection();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionHeader('Recent Content'),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 32),
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.cardBorder),
            ),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.video_library_outlined,
                    size: 40, color: AppTheme.textSecondary),
                SizedBox(height: 12),
                Text(
                  'Content feed coming soon',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 14,
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

// ─────────────────────────────────────────────────────────────────────────────
// SHARED PRIVATE WIDGETS
// ─────────────────────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) => Text(
        title,
        style: const TextStyle(
          color: AppTheme.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      );
}

class _NotFoundState extends StatelessWidget {
  const _NotFoundState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.person_off_outlined,
                size: 56, color: AppTheme.textSecondary),
            const SizedBox(height: 20),
            const Text(
              'Profile not found',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'This username does not exist.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 32),
            OutlinedButton(
              onPressed: () => context.go('/home'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.primary,
                side: const BorderSide(color: AppTheme.primary),
              ),
              child: const Text('Go Home'),
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
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off_rounded,
                size: 48, color: AppTheme.textSecondary),
            const SizedBox(height: 16),
            const Text(
              'Could not load profile',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: onRetry,
              child: const Text(
                'Retry',
                style: TextStyle(color: AppTheme.primary),
              ),
            ),
          ],
        ),
      );
}
