import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../models/challenge_models.dart';
import '../providers/challenge_providers.dart';

// ─────────────────────────────────────────────────────────────────────────────
// PUBLIC ENTRY POINT
// ─────────────────────────────────────────────────────────────────────────────

/// Horizontal shelf of earned badge chips.
/// Shows up to [maxVisible] badges; any beyond that are shown as a "+N" chip.
/// Tap any badge chip → bottom sheet with name, description, passive effect.
class BadgesShelf extends ConsumerWidget {
  final String userId;
  final int maxVisible;

  const BadgesShelf({
    super.key,
    required this.userId,
    this.maxVisible = 10,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final badgesAsync = ref.watch(userBadgesProvider(userId));

    return badgesAsync.when(
      loading: () => const SizedBox(height: 48),
      error: (_, __) => const SizedBox.shrink(),
      data: (badges) {
        if (badges.isEmpty) return const SizedBox.shrink();
        return _BadgesShelfContent(badges: badges, maxVisible: maxVisible);
      },
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHELF CONTENT
// ─────────────────────────────────────────────────────────────────────────────

class _BadgesShelfContent extends StatelessWidget {
  final List<UserBadge> badges;
  final int maxVisible;

  const _BadgesShelfContent({required this.badges, required this.maxVisible});

  @override
  Widget build(BuildContext context) {
    final visible = badges.take(maxVisible).toList();
    final overflow = badges.length - visible.length;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 20),
          child: Text(
            'Badges',
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppTheme.textSecondary,
              letterSpacing: 0.5,
            ),
          ),
        ),
        const SizedBox(height: 8),
        SizedBox(
          height: 60,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            children: [
              for (final badge in visible) ...[
                _BadgeChip(badge: badge),
                const SizedBox(width: 8),
              ],
              if (overflow > 0) _OverflowChip(count: overflow),
            ],
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BADGE CHIP
// ─────────────────────────────────────────────────────────────────────────────

class _BadgeChip extends StatelessWidget {
  final UserBadge badge;

  const _BadgeChip({required this.badge});

  Color get _tierColor {
    switch (badge.definition.tier) {
      case 'gold':
        return const Color(0xFFFFD700);
      case 'silver':
        return const Color(0xFFC0C0C0);
      case 'bronze':
      default:
        return const Color(0xFFCD7F32);
    }
  }

  IconData get _tierIcon {
    switch (badge.definition.tier) {
      case 'gold':
        return Icons.star_rounded;
      case 'silver':
        return Icons.star_half_rounded;
      case 'bronze':
      default:
        return Icons.star_outline_rounded;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tierColor = _tierColor;

    return GestureDetector(
      onTap: () => _showBadgeDetail(context),
      child: Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          color: AppTheme.surface,
          shape: BoxShape.circle,
          border: Border.all(color: tierColor, width: 2),
        ),
        child: Center(
          child: Icon(_tierIcon, color: tierColor, size: 22),
        ),
      ),
    );
  }

  void _showBadgeDetail(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => _BadgeDetailSheet(badge: badge),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// OVERFLOW CHIP
// ─────────────────────────────────────────────────────────────────────────────

class _OverflowChip extends StatelessWidget {
  final int count;

  const _OverflowChip({required this.count});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 52,
      height: 52,
      decoration: BoxDecoration(
        color: AppTheme.surface,
        shape: BoxShape.circle,
        border: Border.all(color: AppTheme.cardBorder, width: 2),
      ),
      child: Center(
        child: Text(
          '+$count',
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.bold,
            color: AppTheme.textSecondary,
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BADGE DETAIL BOTTOM SHEET
// ─────────────────────────────────────────────────────────────────────────────

class _BadgeDetailSheet extends StatelessWidget {
  final UserBadge badge;

  const _BadgeDetailSheet({required this.badge});

  Color get _tierColor {
    switch (badge.definition.tier) {
      case 'gold':
        return const Color(0xFFFFD700);
      case 'silver':
        return const Color(0xFFC0C0C0);
      case 'bronze':
      default:
        return const Color(0xFFCD7F32);
    }
  }

  String get _tierLabel {
    switch (badge.definition.tier) {
      case 'gold':
        return 'Gold';
      case 'silver':
        return 'Silver';
      case 'bronze':
      default:
        return 'Bronze';
    }
  }

  @override
  Widget build(BuildContext context) {
    final tierColor = _tierColor;
    final passive = badge.definition.passiveEffectLabel;

    return Container(
      margin: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: tierColor.withValues(alpha: 0.4)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Handle
          Container(
            width: 40,
            height: 4,
            margin: const EdgeInsets.only(top: 12, bottom: 20),
            decoration: BoxDecoration(
              color: AppTheme.cardBorder,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Badge icon
          Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: tierColor.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(color: tierColor, width: 3),
            ),
            child: Icon(
              badge.definition.tier == 'gold'
                  ? Icons.star_rounded
                  : badge.definition.tier == 'silver'
                      ? Icons.star_half_rounded
                      : Icons.star_outline_rounded,
              color: tierColor,
              size: 36,
            ),
          ),
          const SizedBox(height: 16),

          // Tier label
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
            decoration: BoxDecoration(
              color: tierColor.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: tierColor.withValues(alpha: 0.4)),
            ),
            child: Text(
              _tierLabel,
              style: TextStyle(
                color: tierColor,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1,
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Badge name
          Text(
            badge.definition.name,
            style: const TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 8),

          // Description
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              badge.definition.description,
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 14,
                color: AppTheme.textSecondary,
                height: 1.4,
              ),
            ),
          ),

          // Passive effect
          if (passive != null) ...[
            const SizedBox(height: 16),
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 24),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3)),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.auto_awesome, color: AppTheme.primary, size: 16),
                  const SizedBox(width: 8),
                  Text(
                    passive,
                    style: const TextStyle(
                      color: AppTheme.primary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ],

          const SizedBox(height: 32),
        ],
      ),
    );
  }
}
