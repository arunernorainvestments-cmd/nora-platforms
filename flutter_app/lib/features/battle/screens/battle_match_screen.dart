import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../game/battle_game.dart';
import '../models/battle_models.dart';
import '../widgets/combat_menu.dart';

// TODO(Phase C): replace with Riverpod providers that load from battle_abilities
// and battle_participants for the real match.
const _musicianAbilities = [
  AbilityData(slot: 1, name: 'Rhythm Hit', apCost: 5),
  AbilityData(slot: 2, name: 'Drop the Beat', apCost: 10),
  AbilityData(slot: 3, name: 'Crowd Hype', apCost: 15),
  AbilityData(slot: 4, name: 'Bass Drop', apCost: 25),
  AbilityData(slot: 5, name: 'Encore', apCost: 40, requiresMomentum: true),
];

const _placeholderBench = [
  BenchCharacter(archetype: 'athlete', displayName: 'Athlete', currentHp: 100, maxHp: 120),
  BenchCharacter(archetype: 'gamer', displayName: 'Gamer', currentHp: 55, maxHp: 100),
];

class BattleMatchScreen extends StatefulWidget {
  final String matchId;
  const BattleMatchScreen({super.key, required this.matchId});

  @override
  State<BattleMatchScreen> createState() => _BattleMatchScreenState();
}

class _BattleMatchScreenState extends State<BattleMatchScreen> {
  late final BattleGame _game;

  @override
  void initState() {
    super.initState();
    _game = BattleGame();
  }

  void _onAbility(int slot) {
    _game.triggerAbility(slot);
    // TODO(Phase C): submit turn to battle_turn_submissions via Supabase RPC
  }

  void _onSwap(BenchCharacter character) {
    // TODO(Phase C): submit swap action to battle_turn_submissions
    debugPrint('Swap to ${character.archetype}');
  }

  void _onChit() {
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => Container(
        decoration: const BoxDecoration(
          color: Color(0xFF1A1A2E),
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        padding: const EdgeInsets.fromLTRB(20, 12, 20, 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Center(
              child: Container(
                width: 36, height: 4,
                decoration: BoxDecoration(color: Colors.white24, borderRadius: BorderRadius.circular(2)),
              ),
            ),
            const SizedBox(height: 20),
            const Icon(Icons.style_rounded, color: Color(0xFFFFB300), size: 36),
            const SizedBox(height: 12),
            const Text('Battle Chits', style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
              'No chits collected yet.\nEarn chits through challenges, packs, and gifts.',
              style: TextStyle(color: Colors.white54, fontSize: 13),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: Stack(
        children: [
          // Stage background
          Positioned.fill(
            child: Image.asset(
              'assets/battle/backgrounds/stage_01.png',
              fit: BoxFit.contain,
            ),
          ),

          // Flame game layer (transparent bg)
          GameWidget(game: _game),

          // Back button
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, color: Colors.white),
                    onPressed: () => context.go('/battle'),
                  ),
                  const Spacer(),
                  if (widget.matchId == 'test-match')
                    const Padding(
                      padding: EdgeInsets.only(right: 16),
                      child: Text('Animation Test', style: TextStyle(color: Colors.white38, fontSize: 11)),
                    ),
                ],
              ),
            ),
          ),

          // Combat menu pinned to bottom
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: CombatMenu(
              abilities: _musicianAbilities,
              bench: _placeholderBench,
              momentumReady: false, // TODO(Phase C): wire to momentum state from battle_participants
              onAbility: _onAbility,
              onSwap: _onSwap,
              onChit: _onChit,
            ),
          ),
        ],
      ),
    );
  }
}
