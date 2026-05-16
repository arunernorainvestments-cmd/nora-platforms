import 'package:flutter/material.dart';
import '../../../core/widgets/n_card.dart';
import '../../../core/widgets/n_glass_sheet.dart';
import '../../../core/widgets/n_tappable.dart';
import '../models/battle_models.dart';

class SwapPickerSheet extends StatelessWidget {
  final List<BenchCharacter> bench;
  final void Function(BenchCharacter) onSelect;

  const SwapPickerSheet({
    super.key,
    required this.bench,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return NGlassSheet(
      topRadius: 16,
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const NSheetHandle(),
          const SizedBox(height: 16),
          const Text(
            'Call in a teammate',
            style: TextStyle(
              color: Colors.white,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          ...bench.map((character) => _BenchCard(
                character: character,
                onSelect: () {
                  Navigator.pop(context);
                  onSelect(character);
                },
              )),
        ],
      ),
    );
  }
}

class _BenchCard extends StatelessWidget {
  final BenchCharacter character;
  final VoidCallback onSelect;

  const _BenchCard({required this.character, required this.onSelect});

  @override
  Widget build(BuildContext context) {
    final hpPct = character.currentHp / character.maxHp;
    final hpColor = hpPct > 0.5
        ? const Color(0xFF00C896)
        : hpPct > 0.25
            ? Colors.orange
            : const Color(0xFFFF4757);

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 150),
        opacity: character.isKO ? 0.4 : 1.0,
        child: NTappable(
          onTap: character.isKO ? null : onSelect,
          child: NCard(
            accentColor: const Color(0xFF6C63FF),
            radius: 10,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: const Color(0xFF6C63FF).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(Icons.person,
                      color: Color(0xFF6C63FF), size: 24),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        character.displayName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Row(
                        children: [
                          Expanded(
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(2),
                              child: LinearProgressIndicator(
                                value: hpPct.clamp(0.0, 1.0),
                                backgroundColor: Colors.white12,
                                valueColor:
                                    AlwaysStoppedAnimation(hpColor),
                                minHeight: 4,
                              ),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '${character.currentHp}/${character.maxHp}',
                            style: const TextStyle(
                                color: Colors.white54, fontSize: 11),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                if (character.isKO)
                  const Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Text('KO',
                        style: TextStyle(
                            color: Color(0xFFFF4757),
                            fontSize: 12,
                            fontWeight: FontWeight.bold)),
                  )
                else
                  const Icon(Icons.chevron_right,
                      color: Colors.white38, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
