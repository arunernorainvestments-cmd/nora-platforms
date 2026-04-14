import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../profile/providers/profile_providers.dart';
import '../models/challenge_models.dart';
import '../providers/challenge_providers.dart';

// ─────────────────────────────────────────────────────────────────────────────
// SCREEN
// ─────────────────────────────────────────────────────────────────────────────

class ChallengesScreen extends ConsumerWidget {
  const ChallengesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(userProfileProvider);

    return profileAsync.when(
      loading: () => const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (_, __) => const Scaffold(
        body: Center(child: Text('Failed to load profile')),
      ),
      data: (profile) => _ChallengesBody(isMM: profile?.isMarketMaker ?? false),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BODY (has DefaultTabController)
// ─────────────────────────────────────────────────────────────────────────────

class _ChallengesBody extends ConsumerWidget {
  final bool isMM;

  const _ChallengesBody({required this.isMM});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return DefaultTabController(
      length: 3,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Challenges'),
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Daily'),
              Tab(text: 'Weekly'),
              Tab(text: 'Monthly'),
            ],
            indicatorColor: AppTheme.primary,
            labelColor: AppTheme.primary,
            unselectedLabelColor: AppTheme.textSecondary,
          ),
        ),
        body: TabBarView(
          children: [
            _ChallengeTab(track: 'daily', isMM: isMM),
            _ChallengeTab(track: 'weekly', isMM: isMM),
            _ChallengeTab(track: 'monthly', isMM: isMM),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TAB — one track
// ─────────────────────────────────────────────────────────────────────────────

class _ChallengeTab extends ConsumerWidget {
  final String track; // 'daily' | 'weekly' | 'monthly'
  final bool isMM;

  const _ChallengeTab({required this.track, required this.isMM});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final challengesAsync = ref.watch(allChallengesProvider);
    final progressAsync = ref.watch(challengeProgressProvider);

    if (challengesAsync.isLoading || progressAsync.isLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    if (challengesAsync.hasError || progressAsync.hasError) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('Failed to load challenges',
                style: TextStyle(color: AppTheme.textSecondary)),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () {
                ref.invalidate(allChallengesProvider);
                ref.invalidate(challengeProgressProvider);
              },
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    final allDefs = challengesAsync.value ?? [];
    final allProgress = progressAsync.value ?? [];
    final key = periodKey(track);

    // Filter by track and pool eligibility
    final trackDefs = allDefs.where((c) {
      if (c.track != track) return false;
      if (c.pool == 'mm' && !isMM) return false;
      return true;
    }).toList();

    if (trackDefs.isEmpty) {
      return Center(
        child: Text(
          'No ${_trackLabel(track)} challenges available',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
      );
    }

    // Build progress map keyed by challenge_id
    final progressMap = {
      for (final p in allProgress)
        if (p.periodKey == key) p.challengeId: p,
    };

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: trackDefs.length + 1, // +1 for reset info header
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        if (index == 0) {
          return _ResetInfo(track: track);
        }
        final def = trackDefs[index - 1];
        final progress = progressMap[def.id];
        return _ChallengeCard(definition: def, progress: progress);
      },
    );
  }

  String _trackLabel(String t) {
    switch (t) {
      case 'daily':
        return 'daily';
      case 'weekly':
        return 'weekly';
      case 'monthly':
        return 'monthly';
      default:
        return t;
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// RESET INFO HEADER
// ─────────────────────────────────────────────────────────────────────────────

class _ResetInfo extends StatelessWidget {
  final String track;

  const _ResetInfo({required this.track});

  String get _resetLabel {
    final now = DateTime.now().toUtc();
    switch (track) {
      case 'daily':
        final tomorrow = DateTime.utc(now.year, now.month, now.day + 1);
        final diff = tomorrow.difference(now);
        final h = diff.inHours;
        final m = diff.inMinutes % 60;
        return 'Resets in ${h}h ${m}m';
      case 'weekly':
        final daysUntilMonday = (8 - now.weekday) % 7;
        final days = daysUntilMonday == 0 ? 7 : daysUntilMonday;
        return 'Resets in $days day${days == 1 ? '' : 's'}';
      case 'monthly':
        final nextMonth = DateTime.utc(now.year, now.month + 1, 1);
        final days = nextMonth.difference(now).inDays;
        return 'Resets in $days day${days == 1 ? '' : 's'}';
      default:
        return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        children: [
          const Icon(Icons.schedule, size: 14, color: AppTheme.textSecondary),
          const SizedBox(width: 4),
          Text(
            _resetLabel,
            style: const TextStyle(
              fontSize: 12,
              color: AppTheme.textSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CHALLENGE CARD
// ─────────────────────────────────────────────────────────────────────────────

class _ChallengeCard extends StatelessWidget {
  final ChallengeDefinition definition;
  final ChallengeProgress? progress;

  const _ChallengeCard({required this.definition, this.progress});

  bool get _isCompleted => progress?.isCompleted ?? false;

  int get _current => progress?.currentCount ?? 0;

  int get _required => definition.requiredCount;

  double get _progressFraction =>
      _required > 0 ? (_current / _required).clamp(0.0, 1.0) : 0.0;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: _isCompleted
              ? AppTheme.success.withValues(alpha: 0.4)
              : AppTheme.cardBorder,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Status icon
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: _isCompleted
                  ? AppTheme.success.withValues(alpha: 0.15)
                  : AppTheme.primary.withValues(alpha: 0.1),
              shape: BoxShape.circle,
            ),
            child: Icon(
              _isCompleted ? Icons.check_circle : Icons.emoji_events_outlined,
              color: _isCompleted ? AppTheme.success : AppTheme.primary,
              size: 20,
            ),
          ),
          const SizedBox(width: 12),

          // Content
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Name row
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Flexible(
                      child: Text(
                        definition.displayName,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                          color: _isCompleted
                              ? AppTheme.textSecondary
                              : Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    if (_isCompleted)
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 8, vertical: 2),
                        decoration: BoxDecoration(
                          color: AppTheme.success.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                              color: AppTheme.success.withValues(alpha: 0.3)),
                        ),
                        child: const Text(
                          'Claimed',
                          style: TextStyle(
                            fontSize: 11,
                            color: AppTheme.success,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      )
                    else if (definition.tokenReward > 0)
                      Text(
                        '+${definition.tokenReward}T',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                          color: AppTheme.secondary,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),

                // Progress bar
                if (!_isCompleted) ...[
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _progressFraction,
                      minHeight: 5,
                      backgroundColor: AppTheme.cardBorder,
                      valueColor: AlwaysStoppedAnimation<Color>(
                          AppTheme.primary.withValues(alpha: 0.8)),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '$_current / $_required',
                    style: const TextStyle(
                      fontSize: 11,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ] else ...[
                  Text(
                    definition.tokenReward > 0
                        ? '${definition.tokenReward} tokens'
                        : 'Complete',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],

                // Badge reward label
                if (definition.badgeId != null && !_isCompleted)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(
                      children: [
                        Icon(Icons.star_outline,
                            size: 12,
                            color: const Color(0xFFFFD700).withValues(alpha: 0.8)),
                        const SizedBox(width: 3),
                        Text(
                          'Badge reward',
                          style: TextStyle(
                            fontSize: 11,
                            color: const Color(0xFFFFD700).withValues(alpha: 0.8),
                          ),
                        ),
                      ],
                    ),
                  ),

                // MM-only label
                if (definition.pool == 'mm')
                  const Padding(
                    padding: EdgeInsets.only(top: 4),
                    child: Text(
                      'Market Maker only',
                      style: TextStyle(
                        fontSize: 10,
                        color: AppTheme.textSecondary,
                        fontStyle: FontStyle.italic,
                      ),
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
