import 'package:flutter/material.dart';
import '../../../core/widgets/n_tappable.dart';
import '../models/battle_models.dart';
import 'swap_picker_sheet.dart';

class CombatMenu extends StatelessWidget {
  final List<AbilityData> abilities;
  final List<BenchCharacter> bench;
  final bool momentumReady;
  final int currentAp;
  final void Function(int slot) onAbility;
  final void Function(BenchCharacter) onSwap;
  final VoidCallback onChit;

  const CombatMenu({
    super.key,
    required this.abilities,
    required this.bench,
    required this.currentAp,
    required this.onAbility,
    required this.onSwap,
    required this.onChit,
    this.momentumReady = false,
  });

  AbilityData _slot(int n) => abilities.firstWhere((a) => a.slot == n);

  @override
  Widget build(BuildContext context) {
    final s1 = _slot(1);
    final s2 = _slot(2);
    final s3 = _slot(3);
    final s4 = _slot(4);
    final s5 = _slot(5);
    final ultimateEnabled = momentumReady && currentAp >= s5.apCost;

    return Container(
      color: Colors.black.withValues(alpha: 0.88),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Swap + Chit row
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              _ActionChip(
                label: 'Swap',
                icon: Icons.swap_horiz_rounded,
                color: const Color(0xFF03DAC6),
                onTap: () => showModalBottomSheet(
                  context: context,
                  backgroundColor: Colors.transparent,
                  builder: (_) =>
                      SwapPickerSheet(bench: bench, onSelect: onSwap),
                ),
              ),
              const SizedBox(width: 8),
              _ActionChip(
                label: 'Chit',
                icon: Icons.style_rounded,
                color: const Color(0xFFFFB300),
                onTap: onChit,
              ),
            ],
          ),
          const SizedBox(height: 10),
          // Move grid row 1
          SizedBox(
            height: 64,
            child: Row(
              children: [
                Expanded(
                  child: _MoveBtn(
                    ability: s1,
                    canAfford: currentAp >= s1.apCost,
                    onTap: () => onAbility(1),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _MoveBtn(
                    ability: s2,
                    canAfford: currentAp >= s2.apCost,
                    onTap: () => onAbility(2),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Move grid row 2
          SizedBox(
            height: 64,
            child: Row(
              children: [
                Expanded(
                  child: _MoveBtn(
                    ability: s3,
                    canAfford: currentAp >= s3.apCost,
                    onTap: () => onAbility(3),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _MoveBtn(
                    ability: s4,
                    canAfford: currentAp >= s4.apCost,
                    onTap: () => onAbility(4),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          // Ultimate — full width
          _UltimateBtn(
            ability: s5,
            enabled: ultimateEnabled,
            onTap: () => onAbility(5),
          ),
        ],
      ),
    );
  }
}

// ── Move button (slots 1–4) ───────────────────────────────────────────────────

class _MoveBtn extends StatelessWidget {
  final AbilityData ability;
  final bool canAfford;
  final VoidCallback onTap;

  const _MoveBtn({
    required this.ability,
    required this.canAfford,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return NTappable(
      onTap: canAfford ? onTap : null,
      child: Container(
        decoration: BoxDecoration(
          color: canAfford
              ? const Color(0xFF1A1A2E)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: canAfford
                ? const Color(0xFF6C63FF).withValues(alpha: 0.55)
                : Colors.white.withValues(alpha: 0.1),
          ),
        ),
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              ability.name,
              style: TextStyle(
                color: canAfford ? Colors.white : Colors.white38,
                fontSize: 13,
                fontWeight: FontWeight.w700,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              '${ability.apCost} AP',
              style: TextStyle(
                color: canAfford
                    ? const Color(0xFF6C63FF)
                    : Colors.white.withValues(alpha: 0.2),
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Ultimate button (slot 5) ──────────────────────────────────────────────────

class _UltimateBtn extends StatelessWidget {
  final AbilityData ability;
  final bool enabled;
  final VoidCallback onTap;

  const _UltimateBtn({
    required this.ability,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return NTappable(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        height: 48,
        decoration: BoxDecoration(
          color: enabled
              ? const Color(0xFF6C63FF).withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: enabled
                ? const Color(0xFF6C63FF)
                : Colors.white.withValues(alpha: 0.1),
          ),
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: const Color(0xFF6C63FF).withValues(alpha: 0.35),
                    blurRadius: 14,
                    spreadRadius: 0,
                  ),
                ]
              : [],
        ),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Row(
          children: [
            Icon(
              Icons.bolt_rounded,
              color: enabled ? const Color(0xFF6C63FF) : Colors.white24,
              size: 20,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                ability.name,
                style: TextStyle(
                  color: enabled ? Colors.white : Colors.white38,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.4,
                ),
              ),
            ),
            Text(
              enabled ? '${ability.apCost} AP' : 'NEEDS MOMENTUM',
              style: TextStyle(
                color: enabled
                    ? const Color(0xFF6C63FF)
                    : Colors.white.withValues(alpha: 0.2),
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Action chip (Swap / Chit) ─────────────────────────────────────────────────

class _ActionChip extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _ActionChip({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return NTappable(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.55)),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 16),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 12,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
