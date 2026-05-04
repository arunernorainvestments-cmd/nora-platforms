import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../models/celeb.dart';

class CelebRankCard extends StatelessWidget {
  final CelebWeeklyScore score;
  final int? simpleBetCount;
  final VoidCallback onTap;

  const CelebRankCard({
    super.key,
    required this.score,
    this.simpleBetCount,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final rank = score.rank ?? 99;
    final delta = score.lastDelta;
    final isPositive = delta > 0;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.cardBorder, width: 1),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            // Rank
            SizedBox(
              width: 36,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '#$rank',
                    style: TextStyle(
                      color: rank <= 3 ? AppTheme.primary : AppTheme.textSecondary,
                      fontSize: 13,
                      fontWeight: rank <= 3 ? FontWeight.w800 : FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 2),
                  _MovementIndicator(delta: delta),
                ],
              ),
            ),
            const SizedBox(width: 10),

            // Name + category
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    score.celebName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Row(
                    children: [
                      if (score.celebCategory != null) ...[
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                          decoration: BoxDecoration(
                            color: AppTheme.primary.withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            score.celebCategory!,
                            style: const TextStyle(
                              color: AppTheme.primary,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                      ],
                      if (simpleBetCount != null && simpleBetCount! > 0)
                        Text(
                          '$simpleBetCount betting now',
                          style: TextStyle(
                            color: AppTheme.textSecondary.withValues(alpha: 0.7),
                            fontSize: 11,
                          ),
                        ),
                    ],
                  ),
                  if (score.reasonText != null && score.reasonText!.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      score.reasonText!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: AppTheme.textSecondary.withValues(alpha: 0.85),
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),

            // Points + delta
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  '${score.points}',
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const Text(
                  'pts',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                ),
                if (delta != 0) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: (isPositive ? AppTheme.success : AppTheme.danger)
                          .withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      '${isPositive ? '+' : ''}$delta · ${score.lastTier ?? ''}',
                      style: TextStyle(
                        color: isPositive ? AppTheme.success : AppTheme.danger,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MovementIndicator extends StatelessWidget {
  final int delta;
  const _MovementIndicator({required this.delta});

  @override
  Widget build(BuildContext context) {
    if (delta > 0) {
      return const Icon(Icons.arrow_upward_rounded, color: AppTheme.success, size: 14);
    }
    if (delta < 0) {
      return const Icon(Icons.arrow_downward_rounded, color: AppTheme.danger, size: 14);
    }
    return Icon(Icons.remove_rounded, color: AppTheme.textSecondary.withValues(alpha: 0.5), size: 14);
  }
}
