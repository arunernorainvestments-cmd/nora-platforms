import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../models/active_boost.dart';
import '../providers/promotion_providers.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Entry point
// ─────────────────────────────────────────────────────────────────────────────

void showPowerUpsSheet(
  BuildContext context, {
  required String targetUserId,
  required String targetUsername,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: AppTheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (_) => _PowerUpsSheet(
      targetUserId: targetUserId,
      targetUsername: targetUsername,
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Sheet
// ─────────────────────────────────────────────────────────────────────────────

class _PowerUpsSheet extends ConsumerStatefulWidget {
  final String targetUserId;
  final String targetUsername;
  const _PowerUpsSheet({
    required this.targetUserId,
    required this.targetUsername,
  });

  @override
  ConsumerState<_PowerUpsSheet> createState() => _PowerUpsSheetState();
}

class _PowerUpsSheetState extends ConsumerState<_PowerUpsSheet> {
  String? _loadingType;

  Future<void> _apply(String boostType) async {
    if (_loadingType != null) return;
    setState(() => _loadingType = boostType);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'apply-promotion',
        body: {
          'boost_type': boostType,
          'target_user_id': widget.targetUserId,
        },
      );
      if (res.data?['error'] != null) {
        throw Exception(res.data['error'] as String);
      }
      if (mounted) {
        Navigator.of(context).pop();
        messenger.showSnackBar(
          SnackBar(
            content: Text(_successMessage(boostType, widget.targetUsername)),
            backgroundColor: _isPositive(boostType)
                ? AppTheme.success
                : AppTheme.danger,
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
            backgroundColor: AppTheme.danger,
            behavior: SnackBarBehavior.floating,
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingType = null);
    }
  }

  bool _isPositive(String type) =>
      type == 'universe' || type == 'galaxy' || type == 'instant_plus';

  String _successMessage(String type, String username) => switch (type) {
        'universe' => 'Universe launched on @$username!',
        'galaxy' => 'Galaxy highlight sent to @$username!',
        'instant_plus' => '+Popularity applied to @$username!',
        'instant_minus' => '-Popularity applied to @$username.',
        'black_hole' => 'Black Hole cancelled @$username\'s Universe.',
        _ => 'Power-up applied!',
      };

  @override
  Widget build(BuildContext context) {
    final boostsAsync =
        ref.watch(activeBoostsProvider(widget.targetUserId));

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Handle
            Center(
              child: Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: AppTheme.cardBorder,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            const SizedBox(height: 20),

            Text(
              'Power-Ups for @${widget.targetUsername}',
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 20,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            const Text(
              'Boost or sabotage any Market Maker.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 20),

            boostsAsync.when(
              loading: () => const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(color: AppTheme.primary),
                ),
              ),
              error: (_, __) => _buildCards(activeBoosts: const []),
              data: (boosts) => _buildCards(activeBoosts: boosts),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCards({required List<ActiveBoost> activeBoosts}) {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;

    // Cooldown checks: does this user already have an active universe/galaxy on target?
    bool hasCooldown(String type) => activeBoosts.any(
          (b) =>
              b.boostType == type &&
              b.activatedByUserId == currentUserId &&
              b.isActive,
        );

    // Black Hole is only available if target has an active Universe (by anyone)
    final targetHasUniverse = activeBoosts.any(
      (b) => b.boostType == 'universe' && b.isActive,
    );

    return Column(
      children: [
        // ── Positive boosts ────────────────────────────────────────────────
        const _SectionLabel(label: 'Positive'),
        const SizedBox(height: 8),

        _PowerUpCard(
          emoji: '🌌',
          title: 'Universe',
          subtitle: 'Global animation — your name visible to everyone for 24h',
          cost: 800,
          isLoading: _loadingType == 'universe',
          disabled: _loadingType != null && _loadingType != 'universe',
          cooldownActive: hasCooldown('universe'),
          onTap: () => _apply('universe'),
        ),
        const SizedBox(height: 10),

        _PowerUpCard(
          emoji: '🌠',
          title: 'Galaxy',
          subtitle: 'Name highlight for all followers for 24h',
          cost: 300,
          isLoading: _loadingType == 'galaxy',
          disabled: _loadingType != null && _loadingType != 'galaxy',
          cooldownActive: hasCooldown('galaxy'),
          onTap: () => _apply('galaxy'),
        ),
        const SizedBox(height: 10),

        _PowerUpCard(
          emoji: '📈',
          title: '+Popularity',
          subtitle: '+12 Heat Score for 1 hour',
          cost: 400,
          isLoading: _loadingType == 'instant_plus',
          disabled: _loadingType != null && _loadingType != 'instant_plus',
          onTap: () => _apply('instant_plus'),
        ),
        const SizedBox(height: 20),

        // ── Negative / sabotage ────────────────────────────────────────────
        const _SectionLabel(label: 'Sabotage'),
        const SizedBox(height: 8),

        _PowerUpCard(
          emoji: '📉',
          title: '-Popularity',
          subtitle: '-12 Heat Score for 1 hour (rival sabotage)',
          cost: 350,
          isNegative: true,
          isLoading: _loadingType == 'instant_minus',
          disabled: _loadingType != null && _loadingType != 'instant_minus',
          onTap: () => _apply('instant_minus'),
        ),
        const SizedBox(height: 10),

        _PowerUpCard(
          emoji: '🕳️',
          title: 'Black Hole',
          subtitle: 'Cancels any active Universe on this creator',
          cost: 250,
          isNegative: true,
          isLoading: _loadingType == 'black_hole',
          disabled: _loadingType != null &&
              _loadingType != 'black_hole' ||
              !targetHasUniverse,
          cooldownActive: !targetHasUniverse,
          cooldownLabel: 'No active Universe to cancel',
          onTap: () => _apply('black_hole'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Power-up card
// ─────────────────────────────────────────────────────────────────────────────

class _PowerUpCard extends StatelessWidget {
  final String emoji;
  final String title;
  final String subtitle;
  final int cost;
  final bool isNegative;
  final bool isLoading;
  final bool disabled;
  final bool cooldownActive;
  final String? cooldownLabel;
  final VoidCallback onTap;

  const _PowerUpCard({
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.cost,
    this.isNegative = false,
    required this.isLoading,
    required this.disabled,
    this.cooldownActive = false,
    this.cooldownLabel,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final accentColor = isNegative ? AppTheme.danger : AppTheme.primary;
    final isUnavailable = (disabled || cooldownActive);

    return Opacity(
      opacity: isUnavailable ? 0.45 : 1.0,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: isUnavailable || isLoading ? null : onTap,
          borderRadius: BorderRadius.circular(14),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              color: AppTheme.surfaceLight,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isNegative
                    ? AppTheme.danger.withValues(alpha: 0.3)
                    : AppTheme.cardBorder,
              ),
            ),
            child: Row(
              children: [
                // Icon
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child:
                        Text(emoji, style: const TextStyle(fontSize: 20)),
                  ),
                ),
                const SizedBox(width: 14),

                // Text
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        cooldownActive && cooldownLabel != null
                            ? cooldownLabel!
                            : subtitle,
                        style: TextStyle(
                          color: cooldownActive
                              ? AppTheme.textSecondary
                              : AppTheme.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),

                // Cost / spinner
                if (isLoading)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: AppTheme.primary,
                    ),
                  )
                else
                  Text(
                    '$cost 🪙',
                    style: TextStyle(
                      color: isNegative
                          ? AppTheme.danger
                          : AppTheme.textPrimary,
                      fontSize: 15,
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

class _SectionLabel extends StatelessWidget {
  final String label;
  const _SectionLabel({required this.label});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        label,
        style: const TextStyle(
          color: AppTheme.textSecondary,
          fontSize: 12,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.8,
        ),
      ),
    );
  }
}
