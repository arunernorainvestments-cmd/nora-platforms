import 'dart:async';
import 'package:flame/game.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../game/battle_game.dart';
import '../models/battle_models.dart';
import '../providers/battle_providers.dart';
import '../widgets/battle_hud.dart';
import '../widgets/chit_sheet.dart';
import '../widgets/combat_menu.dart';

// ── Placeholder data (test-match only) ───────────────────────────────────────

// TODO(Phase C): replace with Riverpod providers sourced from battle_abilities
// and battle_participants for the real match.
const _musicianAbilities = [
  AbilityData(slot: 1, name: 'Rhythm Hit',    apCost: 5,  damage: 8),
  AbilityData(slot: 2, name: 'Drop the Beat', apCost: 10, damage: 15),
  AbilityData(slot: 3, name: 'Crowd Hype',    apCost: 15, damage: 20),
  AbilityData(slot: 4, name: 'Bass Drop',     apCost: 25, damage: 35),
  AbilityData(slot: 5, name: 'Encore',        apCost: 40, damage: 55, requiresMomentum: true),
];

const _apRegenPerTurn = 10;
// TODO(Phase C): replace with resolved opponent move damage from battle_events.
const _opponentBaseDamage = 10;

const _placeholderBench = [
  BenchCharacter(archetype: 'athlete',  displayName: 'Athlete', currentHp: 100, maxHp: 120),
  BenchCharacter(archetype: 'gamer',    displayName: 'Gamer',   currentHp: 55,  maxHp: 100),
];

// ─────────────────────────────────────────────────────────────────────────────

class BattleMatchScreen extends ConsumerStatefulWidget {
  final String matchId;
  const BattleMatchScreen({super.key, required this.matchId});

  @override
  ConsumerState<BattleMatchScreen> createState() => _BattleMatchScreenState();
}

class _BattleMatchScreenState extends ConsumerState<BattleMatchScreen> {
  late final BattleGame _game;
  Timer? _turnTimer;

  int _turnSecondsLeft = 30;
  bool _moveSubmitted = false;

  // ── Test-match local state ────────────────────────────────────────────────
  int _playerHp = 80;
  final int _playerMaxHp = 100;
  int _playerAp = 40;
  final int _playerMaxAp = 40;
  int _opponentHp = 100;
  final int _opponentMaxHp = 100;

  // ── Real-match timer sync ─────────────────────────────────────────────────
  int _lastSeenTurn = 0;

  bool get _isTestMatch => widget.matchId == 'test-match';

  @override
  void initState() {
    super.initState();
    _game = BattleGame();
    if (_isTestMatch) _startLocalTimer();
  }

  @override
  void dispose() {
    _turnTimer?.cancel();
    super.dispose();
  }

  // ── Timer helpers ─────────────────────────────────────────────────────────

  void _startLocalTimer() {
    _turnTimer?.cancel();
    _turnTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      if (_turnSecondsLeft > 0) {
        setState(() => _turnSecondsLeft--);
      } else if (!_moveSubmitted) {
        _isTestMatch ? _autoSubmitTest() : setState(() => _moveSubmitted = true);
      }
    });
  }

  void _syncTimerToDeadline(DateTime? deadline) {
    _turnTimer?.cancel();
    final secs = deadline != null
        ? deadline.difference(DateTime.now()).inSeconds.clamp(0, 30)
        : 30;
    if (!mounted) return;
    setState(() => _turnSecondsLeft = secs);
    _startLocalTimer();
  }

  void _onTurnAdvanced(DateTime? newDeadline) {
    if (!mounted) return;
    setState(() => _moveSubmitted = false);
    _syncTimerToDeadline(newDeadline);
  }

  // ── Test-match move logic ─────────────────────────────────────────────────

  void _submitTestMove(int slot) {
    if (_moveSubmitted) return;
    final ability = _musicianAbilities.firstWhere((a) => a.slot == slot);
    setState(() {
      _moveSubmitted = true;
      _playerAp = (_playerAp - ability.apCost).clamp(0, _playerMaxAp);
      _opponentHp = (_opponentHp - ability.damage).clamp(0, _opponentMaxHp);
    });
    _game.triggerAbility(slot);
    _scheduleTestNextTurn();
  }

  void _autoSubmitTest() {
    final affordable = _musicianAbilities
        .where((a) => !a.requiresMomentum && a.apCost <= _playerAp)
        .toList()
      ..sort((a, b) => a.apCost.compareTo(b.apCost));
    final auto = affordable.isNotEmpty ? affordable.first : _musicianAbilities.first;
    _submitTestMove(auto.slot);
  }

  void _scheduleTestNextTurn() {
    Future.delayed(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() {
        _moveSubmitted = false;
        _turnSecondsLeft = 30;
        _playerAp = (_playerAp + _apRegenPerTurn).clamp(0, _playerMaxAp);
        _playerHp = (_playerHp - _opponentBaseDamage).clamp(0, _playerMaxHp);
      });
    });
  }

  // ── Real-match move logic ─────────────────────────────────────────────────

  Future<void> _submitRealMove(String matchId, List<AbilityData> abilities, int slot) async {
    if (_moveSubmitted) return;
    final ability = abilities.where((a) => a.slot == slot).firstOrNull;
    if (ability == null || ability.id == null) return;
    setState(() => _moveSubmitted = true);
    _game.triggerAbility(slot);
    try {
      await Supabase.instance.client.rpc('battle_submit_turn', params: {
        'p_match_id': matchId,
        'p_ability_id': ability.id,
      });
    } catch (e) {
      if (mounted) setState(() => _moveSubmitted = false);
      debugPrint('submit_turn error: $e');
    }
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return _isTestMatch ? _buildTestMatch() : _buildRealMatch();
  }

  // ── Test match (unchanged placeholder behavior) ───────────────────────────

  Widget _buildTestMatch() {
    return _buildScaffold(
      playerHp: _playerHp,
      playerMaxHp: _playerMaxHp,
      playerAp: _playerAp,
      playerMaxAp: _playerMaxAp,
      playerArchetype: 'musician',
      opponentHp: _opponentHp,
      opponentMaxHp: _opponentMaxHp,
      opponentArchetype: 'musician',
      abilities: _musicianAbilities,
      momentumReady: false,
      isTestMatch: true,
      onAbility: _submitTestMove,
      onSwap: (c) => debugPrint('Swap to ${c.archetype}'),
    );
  }

  // ── Real match (Supabase-driven) ──────────────────────────────────────────

  Widget _buildRealMatch() {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    final participantsAsync = ref.watch(battleParticipantsStreamProvider(widget.matchId));
    final matchAsync = ref.watch(battleMatchStreamProvider(widget.matchId));

    // Derive archetype early so the abilities provider watch is unconditional.
    final participants = participantsAsync.value ?? [];
    final me = participants.where((p) => p.userId == currentUserId).firstOrNull;
    final archetype = me?.archetype ?? 'musician';
    final abilitiesAsync = ref.watch(battleAbilitiesProvider(archetype));

    // Sync timer when turn advances.
    ref.listen(battleMatchStreamProvider(widget.matchId), (prev, next) {
      final match = next.value;
      if (match == null) return;
      if (_lastSeenTurn == 0 && match.currentTurn > 0) {
        _lastSeenTurn = match.currentTurn;
        _syncTimerToDeadline(match.turnDeadline);
      } else if (match.currentTurn > _lastSeenTurn) {
        _lastSeenTurn = match.currentTurn;
        _onTurnAdvanced(match.turnDeadline);
      }
    });

    // Match ended.
    if (matchAsync.value?.status == 'resolved') {
      return _buildMatchEnd(matchAsync.value!);
    }

    if (me == null) return _buildLoadingScaffold();

    final opponent = participants
        .where((p) => p.teamNumber != me.teamNumber && p.isActive && !p.isFainted)
        .firstOrNull;

    final abilities = abilitiesAsync.value ?? [];
    final momentumReady = me.momentum >= 100;

    return _buildScaffold(
      playerHp: me.currentHp,
      playerMaxHp: me.maxHp,
      playerAp: me.currentAp,
      playerMaxAp: me.maxAp,
      playerArchetype: me.archetype,
      opponentHp: opponent?.currentHp ?? 0,
      opponentMaxHp: opponent?.maxHp ?? 150,
      opponentArchetype: opponent?.archetype ?? 'musician',
      abilities: abilities,
      momentumReady: momentumReady,
      isTestMatch: false,
      onAbility: (slot) => _submitRealMove(widget.matchId, abilities, slot),
      onSwap: (_) {}, // TODO(Phase C): swap submission
    );
  }

  // ── Shared scaffold ───────────────────────────────────────────────────────

  Widget _buildScaffold({
    required int playerHp,
    required int playerMaxHp,
    required int playerAp,
    required int playerMaxAp,
    required String playerArchetype,
    required int opponentHp,
    required int opponentMaxHp,
    required String opponentArchetype,
    required List<AbilityData> abilities,
    required bool momentumReady,
    required bool isTestMatch,
    required void Function(int) onAbility,
    required void Function(BenchCharacter) onSwap,
  }) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: Stack(
        children: [
          // Stage background — full screen
          Positioned.fill(
            child: Image.asset(
              'assets/battle/backgrounds/stage_01.png',
              fit: BoxFit.contain,
            ),
          ),

          // Flame game layer — IgnorePointer so Flutter overlays receive touches
          IgnorePointer(child: GameWidget(game: _game)),

          // HUD + back button pinned to top
          Positioned(
            top: 0, left: 0, right: 0,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      IconButton(
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                        onPressed: () => context.go('/battle'),
                      ),
                      const Spacer(),
                      if (isTestMatch)
                        const Padding(
                          padding: EdgeInsets.only(right: 16),
                          child: Text('Animation Test', style: TextStyle(color: Colors.white38, fontSize: 11)),
                        ),
                    ],
                  ),
                  BattleHud(
                    playerArchetype: playerArchetype,
                    playerHp: playerHp,
                    playerMaxHp: playerMaxHp,
                    playerAp: playerAp,
                    playerMaxAp: playerMaxAp,
                    opponentArchetype: opponentArchetype,
                    opponentHp: opponentHp,
                    opponentMaxHp: opponentMaxHp,
                    turnSecondsLeft: _turnSecondsLeft,
                  ),
                ],
              ),
            ),
          ),

          // Combat menu pinned to bottom
          Positioned(
            bottom: 0, left: 0, right: 0,
            child: abilities.isEmpty
                ? const SizedBox.shrink()
                : CombatMenu(
                    abilities: abilities,
                    bench: _placeholderBench,
                    currentAp: playerAp,
                    momentumReady: momentumReady,
                    locked: _moveSubmitted,
                    onAbility: onAbility,
                    onSwap: onSwap,
                    onChit: _onChit,
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingScaffold() {
    return const Scaffold(
      backgroundColor: Color(0xFF0A0A0F),
      body: Center(child: CircularProgressIndicator(color: Color(0xFF6C63FF))),
    );
  }

  Widget _buildMatchEnd(BattleMatch match) {
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;
    final participantsAsync = ref.watch(battleParticipantsStreamProvider(widget.matchId));
    final participants = participantsAsync.value ?? [];
    final me = participants.where((p) => p.userId == currentUserId).firstOrNull;
    final won = me != null && match.winnerTeamNumber == me.teamNumber;

    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              won ? 'Victory!' : 'Defeated',
              style: TextStyle(
                color: won ? const Color(0xFF00C896) : const Color(0xFFFF4757),
                fontSize: 36,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 24),
            ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 14),
              ),
              onPressed: () => context.go('/battle'),
              child: const Text('Back to Lobby'),
            ),
          ],
        ),
      ),
    );
  }

  void _onChit() {
    _game.triggerChit();
    // Placeholder combat screen has no real match/participant context yet, so the
    // sheet previews the inventory. When the live combat screen lands, pass the
    // real matchId/participantId + opponents/allies so chits are used via the RPC.
    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (_) => const ChitSheet(),
    );
  }
}
