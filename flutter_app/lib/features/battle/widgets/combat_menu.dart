import 'package:flutter/material.dart';
import '../models/battle_models.dart';
import 'swap_picker_sheet.dart';

class CombatMenu extends StatelessWidget {
  final List<AbilityData> abilities;
  final List<BenchCharacter> bench;
  final bool momentumReady;
  final void Function(int slot) onAbility;
  final void Function(BenchCharacter) onSwap;
  final VoidCallback onChit;

  const CombatMenu({
    super.key,
    required this.abilities,
    required this.bench,
    required this.onAbility,
    required this.onSwap,
    required this.onChit,
    this.momentumReady = false,
  });

  AbilityData _slot(int n) => abilities.firstWhere((a) => a.slot == n);

  @override
  Widget build(BuildContext context) {
    return Container(
      color: Colors.black.withAlpha(200),
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Main ability grid ─────────────────────────────────────────────
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Row 1: slots 1 + 2
                IntrinsicHeight(
                  child: Row(
                    children: [
                      Expanded(child: _AbilityBtn(ability: _slot(1), onTap: () => onAbility(1))),
                      const SizedBox(width: 6),
                      Expanded(child: _AbilityBtn(ability: _slot(2), onTap: () => onAbility(2))),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                // Row 2: slots 3 + 4
                IntrinsicHeight(
                  child: Row(
                    children: [
                      Expanded(child: _AbilityBtn(ability: _slot(3), onTap: () => onAbility(3))),
                      const SizedBox(width: 6),
                      Expanded(child: _AbilityBtn(ability: _slot(4), onTap: () => onAbility(4))),
                    ],
                  ),
                ),
                const SizedBox(height: 6),
                // Row 3: ultimate — full width
                _UltimateBtn(
                  ability: _slot(5),
                  enabled: momentumReady,
                  onTap: () => onAbility(5),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // ── Side column: Swap + Chit ──────────────────────────────────────
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _SideBtn(
                label: 'Swap',
                icon: Icons.swap_horiz_rounded,
                color: const Color(0xFF03DAC6),
                onTap: () => _showSwapPicker(context),
              ),
              const SizedBox(height: 6),
              _SideBtn(
                label: 'Chit',
                icon: Icons.style_rounded,
                color: const Color(0xFFFFB300),
                onTap: onChit,
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showSwapPicker(BuildContext context) {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => SwapPickerSheet(bench: bench, onSelect: onSwap),
    );
  }
}

// ── Ability button ────────────────────────────────────────────────────────────

class _AbilityBtn extends StatelessWidget {
  final AbilityData ability;
  final VoidCallback onTap;

  const _AbilityBtn({required this.ability, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
        decoration: BoxDecoration(
          color: const Color(0xFF6C63FF).withAlpha(40),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF6C63FF).withAlpha(120)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              ability.name,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              '${ability.apCost} AP',
              style: const TextStyle(color: Colors.white38, fontSize: 10),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Ultimate button ───────────────────────────────────────────────────────────

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
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 300),
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: enabled
              ? const Color(0xFF6C63FF).withAlpha(80)
              : Colors.white.withAlpha(10),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: enabled
                ? const Color(0xFF6C63FF)
                : Colors.white24,
          ),
          boxShadow: enabled
              ? [BoxShadow(color: const Color(0xFF6C63FF).withAlpha(120), blurRadius: 12, spreadRadius: 1)]
              : [],
        ),
        child: Row(
          children: [
            Icon(
              Icons.bolt_rounded,
              color: enabled ? const Color(0xFF6C63FF) : Colors.white24,
              size: 16,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                ability.name,
                style: TextStyle(
                  color: enabled ? Colors.white : Colors.white38,
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.5,
                ),
              ),
            ),
            Text(
              enabled ? '${ability.apCost} AP' : 'LOCKED',
              style: TextStyle(
                color: enabled ? const Color(0xFF6C63FF) : Colors.white24,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Side column button (Swap / Chit) ─────────────────────────────────────────

class _SideBtn extends StatelessWidget {
  final String label;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _SideBtn({
    required this.label,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 58,
        padding: const EdgeInsets.symmetric(vertical: 10),
        decoration: BoxDecoration(
          color: color.withAlpha(30),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: color.withAlpha(140)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: color, size: 20),
            const SizedBox(height: 4),
            Text(
              label,
              style: TextStyle(
                color: color,
                fontSize: 10,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
