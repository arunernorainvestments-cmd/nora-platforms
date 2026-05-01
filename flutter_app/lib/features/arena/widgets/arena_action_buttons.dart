import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../models/arena_match.dart';
import '../models/active_effect.dart';
import '../providers/arena_providers.dart';
import 'ability_picker_widget.dart';

class ArenaActionButtons extends ConsumerWidget {
  final ArenaMatch match;
  final void Function(String targetId, int amount) onBack;
  final void Function(String abilityId, String targetId) onTrigger;
  final List<ActiveEffect> activeEffects;

  const ArenaActionButtons({
    super.key,
    required this.match,
    required this.onBack,
    required this.onTrigger,
    required this.activeEffects,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final abilitiesAsync = ref.watch(abilityConfigProvider);
    final cooldownsAsync = ref.watch(abilityCooldownsProvider(match.id));

    return Row(
      children: [
        Expanded(
          child: _BackButton(
            label: match.player1Username,
            color: AppTheme.primary,
            onTap: () => _showBackDialog(context, match.player1Id,
                match.player1Username, AppTheme.primary),
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _BackButton(
            label: match.player2Username,
            color: AppTheme.secondary,
            onTap: () => _showBackDialog(context, match.player2Id,
                match.player2Username, AppTheme.secondary),
          ),
        ),
        const SizedBox(width: 8),
        _TriggerButton(
          onTap: abilitiesAsync.hasValue
              ? () => showAbilityPicker(
                    context: context,
                    match: match,
                    abilities: abilitiesAsync.value!,
                    cooldowns: cooldownsAsync.valueOrNull ?? {},
                    activeEffects: activeEffects,
                    onTrigger: onTrigger,
                  )
              : null,
        ),
      ],
    );
  }

  void _showBackDialog(
    BuildContext context,
    String targetId,
    String targetName,
    Color color,
  ) {
    final controller = TextEditingController(text: '10');
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(
          'Back $targetName',
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text(
              'How many tokens?',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              keyboardType: TextInputType.number,
              autofocus: true,
              style: const TextStyle(color: AppTheme.textPrimary),
              decoration: InputDecoration(
                filled: true,
                fillColor: AppTheme.surfaceLight,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: AppTheme.cardBorder),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: AppTheme.cardBorder),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(color: color),
                ),
                suffixText: 'tokens',
                suffixStyle: const TextStyle(color: AppTheme.textSecondary),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel',
                style: TextStyle(color: AppTheme.textSecondary)),
          ),
          FilledButton(
            onPressed: () {
              final amount = int.tryParse(controller.text.trim());
              if (amount != null && amount > 0) {
                Navigator.of(ctx).pop();
                onBack(targetId, amount);
              }
            },
            style: FilledButton.styleFrom(backgroundColor: color),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }
}

class _BackButton extends StatelessWidget {
  final String label;
  final Color color;
  final VoidCallback onTap;

  const _BackButton({
    required this.label,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: onTap,
      style: FilledButton.styleFrom(
        backgroundColor: color.withValues(alpha: 0.15),
        foregroundColor: color,
        side: BorderSide(color: color.withValues(alpha: 0.4)),
        padding: const EdgeInsets.symmetric(vertical: 14),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('Back', style: TextStyle(fontSize: 11)),
          Text(
            label,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }
}

class _TriggerButton extends StatelessWidget {
  final VoidCallback? onTap;
  const _TriggerButton({this.onTap});

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    return SizedBox(
      width: 56,
      child: FilledButton(
        onPressed: onTap,
        style: FilledButton.styleFrom(
          backgroundColor: enabled
              ? AppTheme.primary.withValues(alpha: 0.18)
              : AppTheme.cardBorder,
          foregroundColor: enabled ? AppTheme.primary : AppTheme.textSecondary,
          disabledBackgroundColor: AppTheme.cardBorder,
          disabledForegroundColor: AppTheme.textSecondary,
          side: BorderSide(
            color: enabled
                ? AppTheme.primary.withValues(alpha: 0.4)
                : AppTheme.cardBorder,
          ),
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.flash_on, size: 16),
            SizedBox(height: 2),
            Text('Ability', style: TextStyle(fontSize: 9)),
          ],
        ),
      ),
    );
  }
}
