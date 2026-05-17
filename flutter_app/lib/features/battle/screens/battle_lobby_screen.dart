import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/battle_models.dart';
import '../providers/battle_providers.dart';

const _archetypes = [
  'athlete', 'musician', 'business', 'comedian', 'artist',
  'gamer', 'influencer', 'scientist', 'politician', 'actor',
];

enum _LobbyPhase { idle, joining, waiting }

class BattleLobbyScreen extends ConsumerStatefulWidget {
  const BattleLobbyScreen({super.key});

  @override
  ConsumerState<BattleLobbyScreen> createState() => _BattleLobbyScreenState();
}

class _BattleLobbyScreenState extends ConsumerState<BattleLobbyScreen> {
  _LobbyPhase _phase = _LobbyPhase.idle;
  String _archetype = 'musician';
  String? _matchId;
  String? _lobbyCode;
  bool _isHost = false;
  int _joinTeam = 2;
  bool _loading = false;
  String? _error;
  final _codeCtrl = TextEditingController();

  @override
  void dispose() {
    _codeCtrl.dispose();
    super.dispose();
  }

  Future<void> _createLobby() async {
    setState(() { _loading = true; _error = null; });
    try {
      final result = await Supabase.instance.client.rpc('battle_create_lobby', params: {
        'p_archetype': _archetype,
        'p_character_name': _archetype[0].toUpperCase() + _archetype.substring(1),
      }) as Map<String, dynamic>;
      setState(() {
        _matchId = result['match_id'] as String;
        _lobbyCode = result['lobby_code'] as String;
        _isHost = true;
        _phase = _LobbyPhase.waiting;
        _loading = false;
      });
    } catch (e) {
      setState(() { _error = e.toString(); _loading = false; });
    }
  }

  Future<void> _joinLobby() async {
    final code = _codeCtrl.text.trim().toUpperCase();
    if (code.length != 6) {
      setState(() => _error = 'Enter the 6-character lobby code.');
      return;
    }
    setState(() { _loading = true; _error = null; });
    try {
      final result = await Supabase.instance.client.rpc('battle_join_lobby', params: {
        'p_lobby_code': code,
        'p_archetype': _archetype,
        'p_character_name': _archetype[0].toUpperCase() + _archetype.substring(1),
        'p_team_number': _joinTeam,
      }) as Map<String, dynamic>;
      setState(() {
        _matchId = result['match_id'] as String;
        _isHost = false;
        _phase = _LobbyPhase.waiting;
        _loading = false;
      });
    } catch (e) {
      setState(() { _error = _friendlyError(e); _loading = false; });
    }
  }

  String _friendlyError(Object e) {
    final msg = e.toString();
    if (msg.contains('Lobby not found')) return 'Lobby not found or already started.';
    if (msg.contains('Team') && msg.contains('full')) return 'That team is full.';
    if (msg.contains('Already joined')) return 'You already joined this match.';
    return 'Something went wrong. Try again.';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: _phase != _LobbyPhase.idle
            ? IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => setState(() {
                  _phase = _LobbyPhase.idle;
                  _error = null;
                  _matchId = null;
                  _lobbyCode = null;
                  _codeCtrl.clear();
                }),
              )
            : null,
        title: const Text('Battle', style: TextStyle(color: Colors.white)),
      ),
      body: SafeArea(
        child: switch (_phase) {
          _LobbyPhase.idle    => _buildIdle(),
          _LobbyPhase.joining => _buildJoining(),
          _LobbyPhase.waiting => _WaitingRoom(
              matchId: _matchId!,
              lobbyCode: _lobbyCode,
              isHost: _isHost,
            ),
        },
      ),
    );
  }

  Widget _buildIdle() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Choose your archetype',
            style: TextStyle(color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _archetypes.map((a) {
              final selected = a == _archetype;
              return GestureDetector(
                onTap: () => setState(() => _archetype = a),
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 150),
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  decoration: BoxDecoration(
                    color: selected
                        ? const Color(0xFF6C63FF).withValues(alpha: 0.2)
                        : Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: selected
                          ? const Color(0xFF6C63FF)
                          : Colors.white.withValues(alpha: 0.15),
                    ),
                  ),
                  child: Text(
                    a[0].toUpperCase() + a.substring(1),
                    style: TextStyle(
                      color: selected ? const Color(0xFF6C63FF) : Colors.white54,
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 32),
          if (_error != null) ...[
            Text(_error!, style: const TextStyle(color: Color(0xFFFF4757), fontSize: 13)),
            const SizedBox(height: 12),
          ],
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _loading ? null : _createLobby,
              child: _loading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Create Lobby', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.3)),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _loading ? null : () => setState(() { _phase = _LobbyPhase.joining; _error = null; }),
              child: const Text('Join with Code', style: TextStyle(fontSize: 15)),
            ),
          ),
          const SizedBox(height: 20),
          // Dev shortcut
          Center(
            child: TextButton(
              onPressed: () => context.go('/battle/test-match'),
              child: const Text('Animation test', style: TextStyle(color: Colors.white24, fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildJoining() {
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Enter lobby code',
            style: TextStyle(color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _codeCtrl,
            autofocus: true,
            textCapitalization: TextCapitalization.characters,
            maxLength: 6,
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp('[A-Za-z0-9]'))],
            style: const TextStyle(color: Colors.white, fontSize: 22, fontWeight: FontWeight.bold, letterSpacing: 8),
            textAlign: TextAlign.center,
            decoration: InputDecoration(
              counterText: '',
              hintText: 'XXXXXX',
              hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.2), letterSpacing: 8, fontSize: 22),
              filled: true,
              fillColor: const Color(0xFF1A1A2E),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(color: Color(0xFF6C63FF)),
              ),
            ),
            onChanged: (_) => setState(() => _error = null),
          ),
          const SizedBox(height: 20),
          const Text('Join as team', style: TextStyle(color: Colors.white54, fontSize: 13)),
          const SizedBox(height: 8),
          Row(
            children: [1, 2].map((t) {
              final selected = _joinTeam == t;
              return Padding(
                padding: const EdgeInsets.only(right: 10),
                child: GestureDetector(
                  onTap: () => setState(() => _joinTeam = t),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                    decoration: BoxDecoration(
                      color: selected ? const Color(0xFF6C63FF).withValues(alpha: 0.2) : Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: selected ? const Color(0xFF6C63FF) : Colors.white.withValues(alpha: 0.15)),
                    ),
                    child: Text('Team $t', style: TextStyle(color: selected ? const Color(0xFF6C63FF) : Colors.white54, fontWeight: FontWeight.bold)),
                  ),
                ),
              );
            }).toList(),
          ),
          const SizedBox(height: 20),
          if (_error != null) ...[
            Text(_error!, style: const TextStyle(color: Color(0xFFFF4757), fontSize: 13)),
            const SizedBox(height: 12),
          ],
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6C63FF),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
              onPressed: _loading ? null : _joinLobby,
              child: _loading
                  ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                  : const Text('Join', style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold)),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Waiting room ──────────────────────────────────────────────────────────────
// Separate widget so ref.watch/ref.listen are only active during this phase.

class _WaitingRoom extends ConsumerStatefulWidget {
  final String matchId;
  final String? lobbyCode;
  final bool isHost;

  const _WaitingRoom({
    required this.matchId,
    required this.lobbyCode,
    required this.isHost,
  });

  @override
  ConsumerState<_WaitingRoom> createState() => _WaitingRoomState();
}

class _WaitingRoomState extends ConsumerState<_WaitingRoom> {
  bool _navigated = false;
  bool _starting = false;
  String? _error;

  Future<void> _startMatch() async {
    setState(() { _starting = true; _error = null; });
    try {
      await Supabase.instance.client.rpc('battle_start_match_dev', params: {
        'p_match_id': widget.matchId,
      });
      // Navigation handled by ref.listen below
    } catch (e) {
      setState(() { _error = _friendlyStartError(e); _starting = false; });
    }
  }

  String _friendlyStartError(Object e) {
    final msg = e.toString();
    if (msg.contains('at least 1 player')) return 'Need at least 1 player per team.';
    return 'Could not start. Try again.';
  }

  @override
  Widget build(BuildContext context) {
    final participantsAsync = ref.watch(battleParticipantsStreamProvider(widget.matchId));

    ref.listen(battleMatchStreamProvider(widget.matchId), (_, next) {
      if (_navigated) return;
      if (next.value?.status == 'active' && mounted) {
        _navigated = true;
        context.go('/battle/${widget.matchId}');
      }
    });

    final participants = participantsAsync.value ?? [];
    final team1 = participants.where((p) => p.teamNumber == 1).toList();
    final team2 = participants.where((p) => p.teamNumber == 2).toList();
    final canStart = widget.isHost && team1.isNotEmpty && team2.isNotEmpty;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (widget.lobbyCode != null) ...[
            const Text('Lobby Code', style: TextStyle(color: Colors.white54, fontSize: 12)),
            const SizedBox(height: 6),
            GestureDetector(
              onTap: () {
                Clipboard.setData(ClipboardData(text: widget.lobbyCode!));
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Code copied'), duration: Duration(seconds: 1)),
                );
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                decoration: BoxDecoration(
                  color: const Color(0xFF1A1A2E),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: const Color(0xFF6C63FF).withValues(alpha: 0.5)),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      widget.lobbyCode!,
                      style: const TextStyle(
                        color: Color(0xFF6C63FF),
                        fontSize: 28,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 10,
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Icon(Icons.copy_rounded, color: Color(0xFF6C63FF), size: 18),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            const Text('Tap to copy — share with your opponent', style: TextStyle(color: Colors.white38, fontSize: 11)),
            const SizedBox(height: 24),
          ],
          _TeamSlot(label: 'Team 1', players: team1),
          const SizedBox(height: 16),
          _TeamSlot(label: 'Team 2', players: team2),
          const Spacer(),
          if (_error != null) ...[
            Text(_error!, style: const TextStyle(color: Color(0xFFFF4757), fontSize: 13)),
            const SizedBox(height: 10),
          ],
          if (widget.isHost)
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: canStart ? const Color(0xFF00C896) : Colors.white12,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onPressed: (canStart && !_starting) ? _startMatch : null,
                child: _starting
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : Text(
                        canStart ? 'Start Battle' : 'Waiting for players…',
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                      ),
              ),
            )
          else
            const Center(
              child: Text('Waiting for host to start…', style: TextStyle(color: Colors.white38, fontSize: 13)),
            ),
        ],
      ),
    );
  }
}

class _TeamSlot extends StatelessWidget {
  final String label;
  final List<BattleParticipant> players;

  const _TeamSlot({required this.label, required this.players});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 12, fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        if (players.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: const Text('Waiting…', style: TextStyle(color: Colors.white24, fontSize: 13)),
          )
        else
          ...players.map((p) => Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: const Color(0xFF1A1A2E),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: const Color(0xFF6C63FF).withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Icon(Icons.person_rounded, color: Color(0xFF6C63FF), size: 16),
                  const SizedBox(width: 8),
                  Text(
                    p.characterName,
                    style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    p.archetype,
                    style: const TextStyle(color: Colors.white38, fontSize: 11),
                  ),
                ],
              ),
            ),
          )),
      ],
    );
  }
}
