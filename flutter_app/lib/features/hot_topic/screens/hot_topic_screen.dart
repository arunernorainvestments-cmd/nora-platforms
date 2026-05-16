import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../models/celeb.dart';
import '../providers/hot_topic_providers.dart';
import '../widgets/celeb_rank_card.dart';
import '../widgets/weekly_banner.dart';
import '../widgets/bet_bottom_sheet.dart';

class HotTopicScreen extends ConsumerWidget {
  const HotTopicScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final week = ref.watch(currentWeekProvider);
    final leaderboardAsync = ref.watch(hotTopicLeaderboardProvider);
    final weeklyBetAsync = ref.watch(currentUserWeeklyBetProvider);

    final weekLabel = _weekLabel(week.start, week.end);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Who\'s Hot Right Now? 🔥',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(
              weekLabel,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.normal,
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh_rounded, color: AppTheme.textSecondary),
            onPressed: () {
              ref.invalidate(hotTopicLeaderboardProvider);
              ref.invalidate(simpleBetCountsProvider);
            },
          ),
        ],
      ),
      body: leaderboardAsync.when(
        loading: () => const Center(child: CircularProgressIndicator(color: AppTheme.primary)),
        error: (err, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off_rounded, size: 48, color: AppTheme.textSecondary),
              const SizedBox(height: 16),
              const Text('Failed to load leaderboard', style: TextStyle(color: AppTheme.textSecondary)),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () => ref.invalidate(hotTopicLeaderboardProvider),
                child: const Text('Retry', style: TextStyle(color: AppTheme.primary)),
              ),
            ],
          ),
        ),
        data: (scores) => _LeaderboardBody(
          scores: scores,
          week: week,
          weeklyBetAsync: weeklyBetAsync,
        ),
      ),
    );
  }

  String _weekLabel(DateTime start, DateTime end) {
    final months = ['Jan','Feb','Mar','Apr','May','Jun','Jul','Aug','Sep','Oct','Nov','Dec'];
    final s = '${months[start.month - 1]} ${start.day}';
    final e = '${months[end.month - 1]} ${end.day}';
    return 'Week of $s – $e';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// LEADERBOARD BODY
// ─────────────────────────────────────────────────────────────────────────────

class _LeaderboardBody extends ConsumerWidget {
  final List<CelebWeeklyScore> scores;
  final WeekInfo week;
  final AsyncValue<WeeklyBet?> weeklyBetAsync;

  const _LeaderboardBody({
    required this.scores,
    required this.week,
    required this.weeklyBetAsync,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final simpleBetCountsAsync = ref.watch(simpleBetCountsProvider);
    final simpleCounts = simpleBetCountsAsync.valueOrNull ?? {};
    final hasWeeklyBet = weeklyBetAsync.valueOrNull != null;

    return Column(
      children: [
        Expanded(
          child: RefreshIndicator(
            color: AppTheme.primary,
            backgroundColor: AppTheme.surface,
            onRefresh: () async {
              ref.invalidate(hotTopicLeaderboardProvider);
              ref.invalidate(simpleBetCountsProvider);
            },
            child: CustomScrollView(
              slivers: [
                // Weekly results banner (Saturday/Sunday only)
                if (week.isResolved)
                  const SliverToBoxAdapter(child: WeeklyBanner()),

                if (scores.isEmpty)
                  const SliverFillRemaining(
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text('🔥', style: TextStyle(fontSize: 40)),
                          SizedBox(height: 12),
                          Text(
                            'Leaderboard loading soon',
                            style: TextStyle(color: AppTheme.textPrimary, fontSize: 16, fontWeight: FontWeight.w600),
                          ),
                          SizedBox(height: 6),
                          Text(
                            'Scoring runs twice daily',
                            style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
                          ),
                        ],
                      ),
                    ),
                  )
                else
                  SliverPadding(
                    padding: const EdgeInsets.only(top: 8, bottom: 100),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate(
                        (context, index) {
                          final score = scores[index];
                          return CelebRankCard(
                            score: score,
                            simpleBetCount: simpleCounts[score.celebId],
                            onTap: () => showHotTopicBetSheet(
                              context,
                              score: score,
                              allScores: scores,
                              onBetPlaced: () {
                                ref.invalidate(simpleBetCountsProvider);
                                ref.invalidate(currentUserWeeklyBetProvider);
                                ref.invalidate(hotTopicTokenBalanceProvider);
                              },
                            ),
                          );
                        },
                        childCount: scores.length,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),

        // Sticky bottom bar
        Container(
          padding: EdgeInsets.fromLTRB(
            16,
            12,
            16,
            12 + MediaQuery.of(context).padding.bottom,
          ),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            border: Border(
                top: BorderSide(
                    color: Colors.white.withValues(alpha: 0.08), width: 1)),
          ),
          child: _PlaceBetButton(
            hasWeeklyBet: hasWeeklyBet,
            isResolved: week.isResolved,
            onTap: scores.isEmpty
                ? null
                : () {
                    if (scores.isNotEmpty) {
                      showHotTopicBetSheet(
                        context,
                        score: scores.first,
                        allScores: scores,
                        onBetPlaced: () {
                          ref.invalidate(simpleBetCountsProvider);
                          ref.invalidate(currentUserWeeklyBetProvider);
                          ref.invalidate(hotTopicTokenBalanceProvider);
                        },
                      );
                    }
                  },
          ),
        ),
      ],
    );
  }
}

class _PlaceBetButton extends StatelessWidget {
  final bool hasWeeklyBet;
  final bool isResolved;
  final VoidCallback? onTap;

  const _PlaceBetButton({
    required this.hasWeeklyBet,
    required this.isResolved,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    String label;
    String subtitle = '';
    bool enabled = onTap != null;

    if (isResolved) {
      label = 'Weekly Betting Closed';
      subtitle = 'Results are being tallied';
      enabled = false;
    } else if (hasWeeklyBet) {
      label = 'Place Quick Bet';
      subtitle = 'Weekly bet already placed — tap a celeb';
    } else {
      label = 'Place Your Bet';
      subtitle = 'Tap a celeb or this button to open the bet sheet';
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        ElevatedButton(
          onPressed: enabled ? onTap : null,
          style: ElevatedButton.styleFrom(
            backgroundColor: enabled ? AppTheme.primary : AppTheme.surface,
            disabledBackgroundColor: AppTheme.surface,
            minimumSize: const Size(double.infinity, 48),
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: enabled ? Colors.white : AppTheme.textSecondary,
              fontWeight: FontWeight.w700,
              fontSize: 15,
            ),
          ),
        ),
        if (subtitle.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
          ),
        ],
      ],
    );
  }
}
