import 'dart:async';
import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../models/arena_match.dart';
import '../models/ability_config.dart';
import '../models/active_effect.dart';

// ── Public entry point ────────────────────────────────────────────────────────
// Shows the bottom sheet and returns when the user dismisses or triggers.
// Target side is chosen by the user inside the sheet.
//
// Design decision: implicit target from backing is ambiguous (users may back
// both sides). Instead the picker shows a P1/P2 toggle at the top so the user
// chooses which player they want to trigger abilities for. The RPC receives
// the resolved target_id based on ability.target + chosen side.

Future<void> showAbilityPicker({
  required BuildContext context,
  required ArenaMatch match,
  required List<AbilityConfig> abilities,
  required Map<String, DateTime> cooldowns,
  required List<ActiveEffect> activeEffects,
  required void Function(String abilityId, String targetId) onTrigger,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: AppTheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    isScrollControlled: true,
    builder: (_) => _AbilityPickerSheet(
      match: match,
      abilities: abilities,
      cooldowns: cooldowns,
      activeEffects: activeEffects,
      onTrigger: onTrigger,
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────

class _AbilityPickerSheet extends StatefulWidget {
  final ArenaMatch match;
  final List<AbilityConfig> abilities;
  final Map<String, DateTime> cooldowns;
  final List<ActiveEffect> activeEffects;
  final void Function(String abilityId, String targetId) onTrigger;

  const _AbilityPickerSheet({
    required this.match,
    required this.abilities,
    required this.cooldowns,
    required this.activeEffects,
    required this.onTrigger,
  });

  @override
  State<_AbilityPickerSheet> createState() => _AbilityPickerSheetState();
}

class _AbilityPickerSheetState extends State<_AbilityPickerSheet> {
  // 1 = supporting P1, 2 = supporting P2
  int _selectedSide = 1;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    // Rebuild every second to update cooldown countdown displays
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  String get _selectedPlayerId =>
      _selectedSide == 1 ? widget.match.player1Id : widget.match.player2Id;
  String get _otherPlayerId =>
      _selectedSide == 1 ? widget.match.player2Id : widget.match.player1Id;
  String get _selectedArchetype =>
      _selectedSide == 1 ? widget.match.player1Archetype : widget.match.player2Archetype;
  String get _selectedUsername =>
      _selectedSide == 1 ? widget.match.player1Username : widget.match.player2Username;
  String? get _selectedSubcategory =>
      _selectedSide == 1 ? widget.match.player1Subcategory : widget.match.player2Subcategory;
  Color get _selectedColor =>
      _selectedSide == 1 ? AppTheme.primary : AppTheme.secondary;

  // For a given ability, computes the target_id to pass to the RPC.
  // 'self' → the player the user is supporting (buff)
  // 'opponent' → the other player (debuff)
  String _resolveTargetId(AbilityConfig ability) {
    return ability.target == 'opponent' ? _otherPlayerId : _selectedPlayerId;
  }

  _CooldownState _cooldownState(AbilityConfig ability) {
    if (ability.isPassive) return _CooldownState.passive;

    final lastUse = widget.cooldowns[ability.id];
    if (lastUse == null) return _CooldownState.ready;

    if (ability.isUltimate) {
      // One per match — permanently on cooldown after first use
      return _CooldownState.permanentCooldown;
    }

    final elapsed = DateTime.now().toUtc().difference(lastUse).inSeconds;
    if (elapsed < ability.cooldownSeconds) {
      return _CooldownState.onCooldown;
    }
    return _CooldownState.ready;
  }

  int _remainingCooldown(AbilityConfig ability) {
    final lastUse = widget.cooldowns[ability.id];
    if (lastUse == null) return 0;
    final elapsed = DateTime.now().toUtc().difference(lastUse).inSeconds;
    return (ability.cooldownSeconds - elapsed).clamp(0, ability.cooldownSeconds);
  }

  // Whether Clutch Play trigger window is met (final 20 s)
  bool _triggerWindowMet(AbilityConfig ability) {
    if (ability.triggerWindow == null) return true;
    if (ability.triggerWindow == 'last_20_seconds') {
      return widget.match.timeRemaining.inSeconds <= 20;
    }
    return true;
  }

  void _confirm(AbilityConfig ability) {
    final targetId = _resolveTargetId(ability);
    final targetName = ability.target == 'opponent'
        ? (_selectedSide == 1 ? widget.match.player2Username : widget.match.player1Username)
        : _selectedUsername;

    showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(
          ability.displayName,
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 16),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ability.description,
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                const Icon(Icons.toll_outlined,
                    color: AppTheme.textSecondary, size: 14),
                const SizedBox(width: 4),
                Text(
                  '${ability.tokenCost} tokens',
                  style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              'Affects: $targetName',
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel',
                style: TextStyle(color: AppTheme.textSecondary)),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: FilledButton.styleFrom(
                backgroundColor: _selectedColor),
            child: Text('Spend ${ability.tokenCost} T'),
          ),
        ],
      ),
    ).then((confirmed) {
      if (confirmed == true && mounted) {
        Navigator.of(context).pop(); // close picker
        widget.onTrigger(ability.id, targetId);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final archetypeAbilities = widget.abilities
        .where((a) => a.archetype == _selectedArchetype && !a.isPassive)
        .toList();

    return DraggableScrollableSheet(
      initialChildSize: 0.55,
      minChildSize: 0.35,
      maxChildSize: 0.85,
      expand: false,
      builder: (_, controller) => Column(
        children: [
          // Handle
          Container(
            margin: const EdgeInsets.only(top: 10, bottom: 4),
            width: 36,
            height: 4,
            decoration: BoxDecoration(
              color: AppTheme.cardBorder,
              borderRadius: BorderRadius.circular(2),
            ),
          ),

          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
            child: Column(
              children: [
                Text(
                  '${_selectedArchetype[0].toUpperCase()}${_selectedArchetype.substring(1)} Abilities',
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                if (_selectedSubcategory != null) ...[
                  const SizedBox(height: 4),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: _selectedColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: _selectedColor.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Text(
                      '${_selectedSubcategory!.replaceAll('_', ' ').toUpperCase()} BONUS',
                      style: TextStyle(
                        color: _selectedColor,
                        fontSize: 9,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                // Side toggle
                Row(
                  children: [
                    _SideToggle(
                      label: widget.match.player1Username,
                      archetype: widget.match.player1Archetype,
                      color: AppTheme.primary,
                      selected: _selectedSide == 1,
                      onTap: () => setState(() => _selectedSide = 1),
                    ),
                    const SizedBox(width: 8),
                    _SideToggle(
                      label: widget.match.player2Username,
                      archetype: widget.match.player2Archetype,
                      color: AppTheme.secondary,
                      selected: _selectedSide == 2,
                      onTap: () => setState(() => _selectedSide = 2),
                    ),
                  ],
                ),
              ],
            ),
          ),

          const Divider(height: 1, color: AppTheme.cardBorder),

          // Ability list
          Expanded(
            child: archetypeAbilities.isEmpty
                ? const Center(
                    child: Text(
                      'No abilities available',
                      style: TextStyle(color: AppTheme.textSecondary),
                    ),
                  )
                : ListView.separated(
                    controller: controller,
                    padding: const EdgeInsets.all(16),
                    itemCount: archetypeAbilities.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 8),
                    itemBuilder: (_, i) {
                      final ability = archetypeAbilities[i];
                      final state = _cooldownState(ability);
                      final windowMet = _triggerWindowMet(ability);
                      final canTrigger =
                          state == _CooldownState.ready && windowMet;

                      return _AbilityRow(
                        ability: ability,
                        cooldownState: state,
                        remainingCooldown: _remainingCooldown(ability),
                        triggerWindowMet: windowMet,
                        accentColor: _selectedColor,
                        onTap: canTrigger ? () => _confirm(ability) : null,
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

enum _CooldownState { ready, onCooldown, permanentCooldown, passive }

class _SideToggle extends StatelessWidget {
  final String label;
  final String archetype;
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _SideToggle({
    required this.label,
    required this.archetype,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Expanded(
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 160),
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 12),
          decoration: BoxDecoration(
            color: selected
                ? color.withValues(alpha: 0.15)
                : AppTheme.surfaceLight.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: selected
                  ? color.withValues(alpha: 0.5)
                  : AppTheme.cardBorder,
            ),
          ),
          child: Column(
            children: [
              Text(
                label,
                style: TextStyle(
                  color: selected ? color : AppTheme.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                archetype.toUpperCase(),
                style: TextStyle(
                  color: selected
                      ? color.withValues(alpha: 0.7)
                      : AppTheme.textSecondary.withValues(alpha: 0.5),
                  fontSize: 9,
                  letterSpacing: 0.5,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AbilityRow extends StatelessWidget {
  final AbilityConfig ability;
  final _CooldownState cooldownState;
  final int remainingCooldown;
  final bool triggerWindowMet;
  final Color accentColor;
  final VoidCallback? onTap;

  const _AbilityRow({
    required this.ability,
    required this.cooldownState,
    required this.remainingCooldown,
    required this.triggerWindowMet,
    required this.accentColor,
    required this.onTap,
  });

  bool get _enabled => onTap != null;

  String _typeLabel() {
    switch (ability.abilityType) {
      case 'core':
        return 'CORE';
      case 'signature':
        return 'SIGNATURE';
      case 'ultimate':
        return 'ULTIMATE';
      default:
        return ability.abilityType.toUpperCase();
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _enabled ? accentColor : AppTheme.textSecondary;

    return GestureDetector(
      onTap: onTap,
      child: AnimatedOpacity(
        opacity: _enabled ? 1.0 : 0.45,
        duration: const Duration(milliseconds: 200),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _enabled
                ? accentColor.withValues(alpha: 0.07)
                : AppTheme.surfaceLight.withValues(alpha: 0.3),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: _enabled
                  ? accentColor.withValues(alpha: 0.25)
                  : AppTheme.cardBorder,
            ),
          ),
          child: Row(
            children: [
              // Type badge + icon
              Column(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      _typeLabel(),
                      style: TextStyle(
                        color: color,
                        fontSize: 8,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.5,
                      ),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Icon(Icons.flash_on, color: color, size: 20),
                ],
              ),
              const SizedBox(width: 12),

              // Name + description
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      ability.displayName,
                      style: TextStyle(
                        color: _enabled
                            ? AppTheme.textPrimary
                            : AppTheme.textSecondary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      ability.description,
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 11),
                    ),
                    if (!triggerWindowMet)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          'Only in final 20 seconds',
                          style: TextStyle(
                              color: AppTheme.danger.withValues(alpha: 0.8),
                              fontSize: 10),
                        ),
                      )
                    else if (cooldownState == _CooldownState.onCooldown)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          'Cooldown: ${remainingCooldown}s',
                          style: TextStyle(
                              color: AppTheme.danger.withValues(alpha: 0.8),
                              fontSize: 10),
                        ),
                      )
                    else if (cooldownState == _CooldownState.permanentCooldown)
                      Padding(
                        padding: const EdgeInsets.only(top: 3),
                        child: Text(
                          'Already used this match',
                          style: TextStyle(
                              color: AppTheme.danger.withValues(alpha: 0.8),
                              fontSize: 10),
                        ),
                      ),
                  ],
                ),
              ),

              const SizedBox(width: 8),

              // Cost
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    '${ability.tokenCost}',
                    style: TextStyle(
                      color: _enabled ? accentColor : AppTheme.textSecondary,
                      fontSize: 16,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const Text(
                    'tokens',
                    style: TextStyle(
                        color: AppTheme.textSecondary, fontSize: 9),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
