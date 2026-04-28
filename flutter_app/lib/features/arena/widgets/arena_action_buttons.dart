import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../models/arena_match.dart';

class ArenaActionButtons extends StatelessWidget {
  final ArenaMatch match;
  final void Function(String targetId, int amount) onBack;

  const ArenaActionButtons({
    super.key,
    required this.match,
    required this.onBack,
  });

  @override
  Widget build(BuildContext context) {
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
        _TriggerButton(),
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
  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'Abilities coming in Phase B',
      child: SizedBox(
        width: 56,
        child: FilledButton(
          onPressed: null,
          style: FilledButton.styleFrom(
            backgroundColor: AppTheme.cardBorder,
            foregroundColor: AppTheme.textSecondary,
            disabledBackgroundColor: AppTheme.cardBorder,
            disabledForegroundColor: AppTheme.textSecondary,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape:
                RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
          ),
          child: const Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.flash_on_outlined, size: 16),
              SizedBox(height: 2),
              Text('Ability', style: TextStyle(fontSize: 9)),
            ],
          ),
        ),
      ),
    );
  }
}
