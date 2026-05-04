import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../models/celeb.dart';
import '../providers/hot_topic_providers.dart';

// Visible Saturday and Sunday UTC (after Friday 8 PM ET resolution).
// Shows Person of the Week (rank 1) and Big Boo (rank 25).
class WeeklyBanner extends ConsumerWidget {
  const WeeklyBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final leaderboardAsync = ref.watch(hotTopicLeaderboardProvider);

    return leaderboardAsync.when(
      loading: () => const SizedBox.shrink(),
      error: (_, __) => const SizedBox.shrink(),
      data: (scores) {
        if (scores.isEmpty) return const SizedBox.shrink();
        final winner = scores.first;
        final bigBoo = scores.last;

        return Container(
          margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                AppTheme.primary.withValues(alpha: 0.15),
                AppTheme.secondary.withValues(alpha: 0.08),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3), width: 1),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(
                children: [
                  Text('🏆', style: TextStyle(fontSize: 16)),
                  SizedBox(width: 8),
                  Text(
                    'WEEK RESULTS',
                    style: TextStyle(
                      color: AppTheme.primary,
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.5,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: _ResultCard(score: winner, label: 'PERSON OF THE WEEK', isWinner: true)),
                  const SizedBox(width: 10),
                  Expanded(child: _ResultCard(score: bigBoo, label: 'BIG BOO', isWinner: false)),
                ],
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ResultCard extends StatelessWidget {
  final CelebWeeklyScore score;
  final String label;
  final bool isWinner;

  const _ResultCard({
    required this.score,
    required this.label,
    required this.isWinner,
  });

  @override
  Widget build(BuildContext context) {
    final color = isWinner ? AppTheme.success : AppTheme.danger;

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.25), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            isWinner ? '👑' : '💀',
            style: const TextStyle(fontSize: 20),
          ),
          const SizedBox(height: 4),
          Text(
            score.celebName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '${score.points} pts',
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
