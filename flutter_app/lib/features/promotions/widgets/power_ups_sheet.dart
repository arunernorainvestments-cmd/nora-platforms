import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/constants/creator_categories.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/n_glass_sheet.dart';
import '../models/active_boost.dart';
import '../providers/promotion_providers.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Entry points
// ─────────────────────────────────────────────────────────────────────────────

enum PowerUpMode { boost, sabotage }

void showBoostSheet(
  BuildContext context, {
  required String targetUserId,
  required String targetUsername,
}) =>
    _openSheet(context,
        targetUserId: targetUserId,
        targetUsername: targetUsername,
        mode: PowerUpMode.boost);

void showSabotageSheet(
  BuildContext context, {
  required String targetUserId,
  required String targetUsername,
}) =>
    _openSheet(context,
        targetUserId: targetUserId,
        targetUsername: targetUsername,
        mode: PowerUpMode.sabotage);

void _openSheet(
  BuildContext context, {
  required String targetUserId,
  required String targetUsername,
  required PowerUpMode mode,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _PowerUpsSheet(
      targetUserId: targetUserId,
      targetUsername: targetUsername,
      mode: mode,
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Sheet
// ─────────────────────────────────────────────────────────────────────────────

class _PowerUpsSheet extends ConsumerStatefulWidget {
  final String targetUserId;
  final String targetUsername;
  final PowerUpMode mode;
  const _PowerUpsSheet({
    required this.targetUserId,
    required this.targetUsername,
    required this.mode,
  });

  @override
  ConsumerState<_PowerUpsSheet> createState() => _PowerUpsSheetState();
}

class _PowerUpsSheetState extends ConsumerState<_PowerUpsSheet> {
  String? _loadingType;

  Future<void> _apply(String boostType, {String? category}) async {
    if (_loadingType != null) return;
    setState(() => _loadingType = boostType);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final body = boostType == 'super_massive_black_hole'
          ? {'boost_type': boostType, 'category': category}
          : {'boost_type': boostType, 'target_user_id': widget.targetUserId};

      final res = await Supabase.instance.client.functions.invoke(
        'apply-promotion',
        body: body,
      );
      if (res.data?['error'] != null) throw Exception(res.data['error'] as String);
      if (mounted) {
        Navigator.of(context).pop();
        messenger.showSnackBar(
          SnackBar(
            content: Text(_successMessage(boostType, category: category)),
            backgroundColor: _isPositive(boostType) ? AppTheme.success : AppTheme.danger,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
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
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _loadingType = null);
    }
  }

  Future<void> _pickCategoryAndApplySMBH() async {
    final selected = await showDialog<String>(
      context: context,
      builder: (ctx) => const _CategoryPickerDialog(),
    );
    if (selected != null && mounted) {
      await _apply('super_massive_black_hole', category: selected);
    }
  }

  bool _isPositive(String type) =>
      type == 'universe' || type == 'galaxy' || type == 'instant_plus';

  String _successMessage(String type, {String? category}) => switch (type) {
        'universe' => 'Universe launched on @${widget.targetUsername}!',
        'galaxy' => 'Galaxy sent for @${widget.targetUsername}!',
        'instant_plus' => '+Popularity applied to @${widget.targetUsername}!',
        'instant_minus' => '-Popularity applied to @${widget.targetUsername}.',
        'black_hole' => 'Black Hole cancelled all effects on @${widget.targetUsername}.',
        'super_massive_black_hole' => 'Super Massive Black Hole wiped all Galaxy effects in $category!',
        _ => 'Power-up applied!',
      };

  @override
  Widget build(BuildContext context) {
    final boostsAsync = ref.watch(activeBoostsProvider(widget.targetUserId));

    return NGlassSheet(
      child: SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const NSheetHandle(),
              const SizedBox(height: 20),
            Text(
              widget.mode == PowerUpMode.boost
                  ? '🚀 Boost @${widget.targetUsername}'
                  : '💀 Sabotage @${widget.targetUsername}',
              style: const TextStyle(
                color: AppTheme.textPrimary, fontSize: 20, fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              widget.mode == PowerUpMode.boost
                  ? 'Increase visibility and heat for this creator.'
                  : 'Reduce visibility or cancel active effects.',
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
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
      ),
    );
  }

  Widget _buildCards({required List<ActiveBoost> activeBoosts}) {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;

    bool hasCooldown(String type) => activeBoosts.any(
          (b) => b.boostType == type && b.activatedByUserId == currentUserId && b.isActive,
        );

    final targetHasUniverseOrGalaxy = activeBoosts.any(
      (b) => (b.boostType == 'universe' || b.boostType == 'galaxy') && b.isActive,
    );

    if (widget.mode == PowerUpMode.boost) {
      return SingleChildScrollView(
        child: Column(
          children: [
            _PowerUpCard(
              emoji: '🌌',
              title: 'Universe',
              subtitle: 'Animated banner visible to everyone for 4 hours',
              cost: 800,
              isLoading: _loadingType == 'universe',
              disabled: (_loadingType != null && _loadingType != 'universe') || hasCooldown('universe'),
              cooldownActive: hasCooldown('universe'),
              cooldownLabel: 'Your Universe is already active on this creator',
              onTap: () => _apply('universe'),
            ),
            const SizedBox(height: 10),
            _PowerUpCard(
              emoji: '🌠',
              title: 'Galaxy',
              subtitle: 'Banner to users with bets in same category for 4 hours',
              cost: 300,
              isLoading: _loadingType == 'galaxy',
              disabled: (_loadingType != null && _loadingType != 'galaxy') || hasCooldown('galaxy'),
              cooldownActive: hasCooldown('galaxy'),
              cooldownLabel: 'Your Galaxy is already active on this creator',
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
          ],
        ),
      );
    }

    // Sabotage mode
    return SingleChildScrollView(
      child: Column(
        children: [
          _PowerUpCard(
            emoji: '📉',
            title: '-Popularity',
            subtitle: '-12 Heat Score for 1 hour',
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
            subtitle: 'Cancels all active Universe & Galaxy on this creator',
            cost: 250,
            isNegative: true,
            isLoading: _loadingType == 'black_hole',
            disabled: (_loadingType != null && _loadingType != 'black_hole') || !targetHasUniverseOrGalaxy,
            cooldownActive: !targetHasUniverseOrGalaxy,
            cooldownLabel: 'No active Universe or Galaxy to cancel',
            onTap: () => _apply('black_hole'),
          ),
          const SizedBox(height: 10),
          _PowerUpCard(
            emoji: '💀',
            title: 'Super Massive Black Hole',
            subtitle: 'Cancels every active Galaxy in a chosen category',
            cost: 800,
            isNegative: true,
            isLoading: _loadingType == 'super_massive_black_hole',
            disabled: _loadingType != null && _loadingType != 'super_massive_black_hole',
            onTap: _pickCategoryAndApplySMBH,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Category picker dialog for Super Massive Black Hole
// ─────────────────────────────────────────────────────────────────────────────

class _CategoryPickerDialog extends StatelessWidget {
  const _CategoryPickerDialog();

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: AppTheme.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: const Text(
        'Choose Category',
        style: TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.bold),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: ListView.separated(
          shrinkWrap: true,
          itemCount: kPrimaryCategories.length,
          separatorBuilder: (_, __) => const Divider(
            height: 1,
            color: AppTheme.cardBorder,
          ),
          itemBuilder: (context, i) {
            final cat = kPrimaryCategories[i];
            return InkWell(
              borderRadius: BorderRadius.circular(8),
              onTap: () => Navigator.of(context).pop(cat),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 4),
                child: Text(
                  cat,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 15,
                  ),
                ),
              ),
            );
          },
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel', style: TextStyle(color: AppTheme.textSecondary)),
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
    final isUnavailable = disabled || cooldownActive;

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
                Container(
                  width: 44, height: 44,
                  decoration: BoxDecoration(
                    color: accentColor.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: Center(
                    child: Text(emoji, style: const TextStyle(fontSize: 20)),
                  ),
                ),
                const SizedBox(width: 14),
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
                        cooldownActive && cooldownLabel != null ? cooldownLabel! : subtitle,
                        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                      ),
                    ],
                  ),
                ),
                if (isLoading)
                  const SizedBox(
                    width: 20, height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AppTheme.primary),
                  )
                else
                  Text(
                    '$cost 🪙',
                    style: TextStyle(
                      color: isNegative ? AppTheme.danger : AppTheme.textPrimary,
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

