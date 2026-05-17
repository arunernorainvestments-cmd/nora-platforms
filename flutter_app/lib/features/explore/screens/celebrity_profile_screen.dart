import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../hot_topic/models/celeb.dart';
import '../../hot_topic/providers/hot_topic_providers.dart';

class CelebrityProfileScreen extends ConsumerWidget {
  final String celebId;
  const CelebrityProfileScreen({super.key, required this.celebId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(celebProfileProvider(celebId));

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: Colors.white, size: 20),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/news'),
        ),
      ),
      body: profileAsync.when(
        loading: () => const Center(
          child: CircularProgressIndicator(color: AppTheme.primary, strokeWidth: 2),
        ),
        error: (_, __) => Center(
          child: Text(
            'Could not load profile',
            style: TextStyle(color: Colors.white.withValues(alpha: 0.5)),
          ),
        ),
        data: (profile) => _ProfileBody(profile: profile),
      ),
    );
  }
}

// ── Avatar color helper (consistent with news feed) ───────────────────────────

Color _avatarColor(String name) {
  const palette = [
    Color(0xFF00BCD4), Color(0xFF9C27B0), Color(0xFF3F51B5),
    Color(0xFFF44336), Color(0xFFFF8F00), Color(0xFF8BC34A),
    Color(0xFF009688), Color(0xFFE91E63), Color(0xFF03A9F4),
    Color(0xFFFF5722), Color(0xFF607D8B), Color(0xFF795548),
  ];
  int hash = 0;
  for (final ch in name.codeUnits) {
    hash = (hash * 31 + ch) & 0x7FFFFFFF;
  }
  return palette[hash % palette.length];
}

String _initials(String name) {
  final words = name.trim().split(RegExp(r'\s+'));
  if (words.length >= 2) return '${words[0][0]}${words[1][0]}'.toUpperCase();
  return name.isNotEmpty ? name[0].toUpperCase() : '?';
}

String _tierLabel(String? tier) {
  const labels = {
    'Good 4': 'Major moment',
    'Good 3': 'Strong positive',
    'Good 2': 'Positive coverage',
    'Good 1': 'Mild positive',
    'Neutral': 'Neutral',
    'Bad 1': 'Mild criticism',
    'Bad 2': 'Controversy',
    'Bad 3': 'Serious negative',
    'Bad 4': 'Major fallout',
  };
  return labels[tier] ?? (tier ?? 'Neutral');
}

// ── Profile body ──────────────────────────────────────────────────────────────

class _ProfileBody extends StatelessWidget {
  final CelebProfileData profile;
  const _ProfileBody({required this.profile});

  @override
  Widget build(BuildContext context) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(child: _HeroHeader(profile: profile)),
        SliverToBoxAdapter(child: _WeeklyBuzzCard(profile: profile)),
        if (profile.history.isNotEmpty) ...[
          SliverToBoxAdapter(child: _SparklineSection(history: profile.history)),
          const SliverToBoxAdapter(
            child: Padding(
              padding: EdgeInsets.fromLTRB(20, 24, 20, 10),
              child: Text(
                'RECENT COVERAGE',
                style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          ),
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 32),
            sliver: SliverList(
              delegate: SliverChildBuilderDelegate(
                (_, i) => _HistoryCard(entry: profile.history[i]),
                childCount: profile.history.length,
              ),
            ),
          ),
        ] else
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.all(40),
              child: Center(
                child: Text(
                  'No coverage history yet',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

// ── Hero header ───────────────────────────────────────────────────────────────

class _HeroHeader extends StatelessWidget {
  final CelebProfileData profile;
  const _HeroHeader({required this.profile});

  @override
  Widget build(BuildContext context) {
    final color = _avatarColor(profile.name);
    final initials = _initials(profile.name);
    final rankText = profile.rank != null ? '#${profile.rank}' : '—';

    return Container(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 24),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: AppTheme.cardBorder)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Large avatar
          Container(
            width: 80,
            height: 80,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.2),
              shape: BoxShape.circle,
              border: Border.all(color: color.withValues(alpha: 0.6), width: 2.5),
            ),
            child: Center(
              child: Text(
                initials,
                style: TextStyle(
                  color: color,
                  fontSize: 26,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          const SizedBox(width: 18),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profile.name,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    height: 1.2,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    if (profile.category != null) ...[
                      _Pill(
                        label: profile.category!,
                        color: AppTheme.primary,
                      ),
                      const SizedBox(width: 8),
                    ],
                    _Pill(
                      label: 'Rank $rankText',
                      color: AppTheme.secondary,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ── Weekly buzz card ──────────────────────────────────────────────────────────

class _WeeklyBuzzCard extends StatelessWidget {
  final CelebProfileData profile;
  const _WeeklyBuzzCard({required this.profile});

  @override
  Widget build(BuildContext context) {
    final deltaColor = profile.lastDelta > 0
        ? AppTheme.success
        : profile.lastDelta < 0
            ? AppTheme.danger
            : Colors.white.withValues(alpha: 0.4);
    final deltaLabel = profile.lastDelta > 0
        ? '+${profile.lastDelta} pts'
        : profile.lastDelta < 0
            ? '${profile.lastDelta} pts'
            : 'No change';
    final barValue = ((profile.points - 1000) / 500 + 0.5).clamp(0.0, 1.0);

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'BUZZ THIS WEEK',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 14),
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(
                '${profile.points}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 36,
                  fontWeight: FontWeight.w800,
                  height: 1,
                ),
              ),
              const SizedBox(width: 6),
              const Padding(
                padding: EdgeInsets.only(bottom: 4),
                child: Text(
                  'pts',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: deltaColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: deltaColor.withValues(alpha: 0.4)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      profile.lastDelta > 0
                          ? Icons.arrow_drop_up
                          : profile.lastDelta < 0
                              ? Icons.arrow_drop_down
                              : Icons.remove,
                      color: deltaColor,
                      size: 18,
                    ),
                    Text(
                      deltaLabel,
                      style: TextStyle(
                        color: deltaColor,
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Score bar (1000 = baseline center)
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: barValue,
              backgroundColor: Colors.white.withValues(alpha: 0.08),
              valueColor: AlwaysStoppedAnimation(
                profile.points >= 1000 ? AppTheme.success : AppTheme.danger,
              ),
              minHeight: 6,
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Icon(Icons.article_outlined,
                  size: 13, color: Colors.white.withValues(alpha: 0.4)),
              const SizedBox(width: 5),
              Text(
                '${profile.weekStoryVolume} stories this week',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.45),
                  fontSize: 12,
                ),
              ),
              if (profile.lastTier != null) ...[
                Text(
                  '  ·  ',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.2), fontSize: 12),
                ),
                Text(
                  _tierLabel(profile.lastTier),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.45),
                    fontSize: 12,
                  ),
                ),
              ],
            ],
          ),
          if (profile.lastReasonText != null &&
              profile.lastReasonText!.isNotEmpty) ...[
            const SizedBox(height: 12),
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
              ),
              child: Text(
                profile.lastReasonText!,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.7),
                  fontSize: 13,
                  height: 1.5,
                  fontStyle: FontStyle.italic,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ── Sparkline (delta history bars) ───────────────────────────────────────────

class _SparklineSection extends StatelessWidget {
  final List<NewsfeedEntry> history;
  const _SparklineSection({required this.history});

  @override
  Widget build(BuildContext context) {
    // Show up to 14 most recent, reversed so oldest is left
    final entries = history.take(14).toList().reversed.toList();
    if (entries.isEmpty) return const SizedBox.shrink();

    final maxAbs =
        entries.map((e) => e.delta.abs()).reduce((a, b) => a > b ? a : b);
    final scale = maxAbs > 0 ? 36.0 / maxAbs : 1.0;

    return Container(
      margin: const EdgeInsets.fromLTRB(16, 20, 16, 0),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'SCORE HISTORY',
            style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 16),
          SizedBox(
            height: 56,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: entries.map((e) {
                final barH = (e.delta.abs() * scale).clamp(3.0, 36.0);
                final color = e.isPositive
                    ? AppTheme.success
                    : e.isNegative
                        ? AppTheme.danger
                        : Colors.white.withValues(alpha: 0.2);
                return Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Container(
                          height: barH,
                          decoration: BoxDecoration(
                            color: color.withValues(alpha: 0.8),
                            borderRadius: BorderRadius.circular(2),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          e.scoringWindow,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.25),
                            fontSize: 8,
                          ),
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
          const SizedBox(height: 6),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                'Older',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.2), fontSize: 10),
              ),
              Text(
                'Latest',
                style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.2), fontSize: 10),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ── Individual history card ───────────────────────────────────────────────────

class _HistoryCard extends StatelessWidget {
  final NewsfeedEntry entry;
  const _HistoryCard({required this.entry});

  @override
  Widget build(BuildContext context) {
    final deltaColor = entry.isPositive
        ? AppTheme.success
        : entry.isNegative
            ? AppTheme.danger
            : Colors.white.withValues(alpha: 0.3);

    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: deltaColor.withValues(alpha: 0.18)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Delta pill
          Container(
            width: 56,
            padding: const EdgeInsets.symmetric(vertical: 5),
            decoration: BoxDecoration(
              color: deltaColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: deltaColor.withValues(alpha: 0.3)),
            ),
            child: Column(
              children: [
                Icon(
                  entry.isPositive
                      ? Icons.arrow_drop_up
                      : entry.isNegative
                          ? Icons.arrow_drop_down
                          : Icons.remove,
                  color: deltaColor,
                  size: 18,
                ),
                Text(
                  entry.deltaLabel,
                  style: TextStyle(
                    color: deltaColor,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                  ),
                  textAlign: TextAlign.center,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      _tierLabel(entry.tier),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      entry.timestampLabel,
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.35),
                        fontSize: 11,
                      ),
                    ),
                  ],
                ),
                if (entry.reasonText != null &&
                    entry.reasonText!.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    entry.reasonText!,
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.65),
                      fontSize: 12,
                      height: 1.5,
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  '${entry.storyVolume} sources · ${entry.scoringWindow} session',
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.3),
                    fontSize: 11,
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

// ── Pill badge ────────────────────────────────────────────────────────────────

class _Pill extends StatelessWidget {
  final String label;
  final Color color;
  const _Pill({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
