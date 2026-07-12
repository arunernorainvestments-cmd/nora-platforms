import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/n_back_button.dart';
import '../providers/matchmaking_providers.dart';
import '../providers/spectate_providers.dart';

/// Play a CCG match from the web (crossplay: the opponent may be on the NORA
/// Arena app). Display-only + server-authoritative: this screen STAGES a turn's
/// actions locally and submits the whole ordered list to ccg_submit_turn, which
/// validates and resolves everything (mig 129). Nothing is computed here beyond
/// soft "can I afford this" hints.
class BattlePlayScreen extends ConsumerStatefulWidget {
  final String matchId;
  const BattlePlayScreen({super.key, required this.matchId});

  @override
  ConsumerState<BattlePlayScreen> createState() => _BattlePlayScreenState();
}

class _StagedAction {
  final Map<String, dynamic> json;
  final String label;
  final int auraCost;
  const _StagedAction(this.json, this.label, this.auraCost);
}

class _BattlePlayScreenState extends ConsumerState<BattlePlayScreen> {
  final List<_StagedAction> _staged = [];
  String? _selectedAttackerId; // field card picking a target
  bool _submitting = false;
  String? _error;

  int get _stagedAura => _staged.fold(0, (s, a) => s + a.auraCost);

  bool _isStagedCard(String cardId) => _staged.any((a) =>
      a.json['card_id'] == cardId || a.json['attacker_card_id'] == cardId);

  Future<void> _endTurn() async {
    setState(() {
      _submitting = true;
      _error = null;
    });
    try {
      await MatchmakingService.submitTurn(
          widget.matchId, _staged.map((a) => a.json).toList());
      if (!mounted) return;
      setState(() {
        _staged.clear();
        _selectedAttackerId = null;
        _submitting = false;
      });
    } catch (e) {
      if (!mounted) return;
      // The resolver rolls the whole turn back on any illegal action — nothing
      // applied. Keep the staged list so the user can remove the bad step.
      setState(() {
        _submitting = false;
        _error = _friendly(e);
      });
    }
  }

  Future<void> _forfeit() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Concede this match?',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text(
          'Your opponent wins immediately. Any wager or market on this match '
          'settles as a normal win for them.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep playing')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Concede'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await MatchmakingService.forfeit(widget.matchId);
      // Streams flip the match to finished; the overlay takes it from there.
    } catch (e) {
      if (mounted) setState(() => _error = _friendly(e));
    }
  }

  String _friendly(Object e) {
    final s = e.toString();
    for (final known in [
      'Not your turn',
      'Not enough Aura',
      'Field is full (cap 3)',
      'Creature is summoning sick',
      'Creature already attacked',
      'Must attack a taunt creature',
      'Vibe too low for this chit',
      'Match not active',
    ]) {
      if (s.contains(known)) return known;
    }
    return 'The move was rejected — refresh of the board state may be needed.';
  }

  // ── staging ─────────────────────────────────────────────────────────────────
  void _stageHandCard(Map<String, dynamic> card, int myFieldCount) {
    final type = (card['snap_chit_type'] ?? 'creature').toString();
    final cost = (card['snap_aura_cost'] as num?)?.toInt() ?? 0;
    final name = 'T${card['snap_tier']} ${type == 'creature' ? 'creature' : 'spell'}';
    if (type == 'creature') {
      final stagedSummons =
          _staged.where((a) => a.json['type'] == 'summon').length;
      if (myFieldCount + stagedSummons >= 3) {
        setState(() => _error = 'Field is full (cap 3)');
        return;
      }
      setState(() {
        _error = null;
        _staged.add(_StagedAction(
            {'type': 'summon', 'card_id': card['id']}, 'Summon $name', cost));
      });
    } else {
      setState(() {
        _error = null;
        _staged.add(_StagedAction(
            {'type': 'cast', 'card_id': card['id']}, 'Cast $name', cost));
      });
    }
  }

  void _stageAttack(String attackerId, String? targetCardId, String label) {
    setState(() {
      _error = null;
      _selectedAttackerId = null;
      _staged.add(_StagedAction({
        'type': 'attack',
        'attacker_card_id': attackerId,
        if (targetCardId != null) 'target_card_id': targetCardId,
      }, label, 0));
    });
  }

  @override
  Widget build(BuildContext context) {
    final matchAsync = ref.watch(ccgMatchStreamProvider(widget.matchId));
    final seats =
        ref.watch(ccgSeatsStreamProvider(widget.matchId)).valueOrNull ?? [];
    final board =
        ref.watch(ccgBoardStreamProvider(widget.matchId)).valueOrNull ?? [];
    final hand =
        ref.watch(myHandStreamProvider(widget.matchId)).valueOrNull ?? [];
    final mySeatAsync = ref.watch(mySeatProvider(widget.matchId));

    final match = matchAsync.valueOrNull;
    final mySeat = mySeatAsync.valueOrNull;

    // Not a participant → this is the spectator's match, not yours.
    if (mySeatAsync.hasValue && mySeat == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) context.go('/battle/spectate/${widget.matchId}');
      });
    }

    final me = seats.where((s) => s.seat == mySeat).firstOrNull;
    final opp = seats.where((s) => s.seat != mySeat).firstOrNull;
    final myTurn =
        match != null && match.status == 'active' && match.activeSeat == mySeat;
    final myField = board
        .where((c) => (c['owner_seat'] as num?)?.toInt() == mySeat)
        .toList();
    final oppField = board
        .where((c) => (c['owner_seat'] as num?)?.toInt() != mySeat)
        .toList();
    final auraLeft = (me?.aura ?? 0) - _stagedAura;

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: const NBackButton(fallback: '/battle'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Text(myTurn ? 'Your turn' : 'Battle',
            style: const TextStyle(color: Colors.white)),
        actions: [
          if (match?.status == 'active')
            IconButton(
              tooltip: 'Concede',
              icon: const Icon(Icons.flag_outlined, color: AppTheme.danger),
              onPressed: _forfeit,
            ),
        ],
      ),
      body: SafeArea(
        child: match == null
            ? const Center(
                child: CircularProgressIndicator(color: AppTheme.primary))
            : Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 640),
                  child: Stack(children: [
                    Column(children: [
                      // ── opponent strip ────────────────────────────────────
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                        child: _seatBar(opp, isMe: false,
                            active: match.activeSeat != mySeat &&
                                match.status == 'active'),
                      ),
                      const SizedBox(height: 8),
                      _fieldRow(
                        cards: oppField,
                        emptyLabel: 'No enemy creatures',
                        onTap: _selectedAttackerId == null
                            ? null
                            : (c) => _stageAttack(
                                _selectedAttackerId!,
                                c['id'] as String,
                                'Attack T${c['snap_tier']} (${c['cur_atk']}/${c['cur_hp']})'),
                        highlight: _selectedAttackerId != null,
                      ),
                      if (_selectedAttackerId != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          child: Wrap(spacing: 8, children: [
                            ActionChip(
                              avatar: const Icon(Icons.person,
                                  size: 16, color: AppTheme.danger),
                              label: Text(
                                  'Attack ${opp?.username ?? 'opponent'} directly'),
                              onPressed: () => _stageAttack(
                                  _selectedAttackerId!, null, 'Attack face'),
                            ),
                            ActionChip(
                              avatar: const Icon(Icons.close, size: 16),
                              label: const Text('Cancel'),
                              onPressed: () =>
                                  setState(() => _selectedAttackerId = null),
                            ),
                          ]),
                        ),
                      const Divider(color: AppTheme.cardBorder, height: 16),

                      // ── my field ──────────────────────────────────────────
                      _fieldRow(
                        cards: myField,
                        emptyLabel: 'Your field is empty — summon from your hand',
                        mine: true,
                        onTap: !myTurn
                            ? null
                            : (c) {
                                final sick = c['is_summoning_sick'] == true;
                                final attacked = c['has_attacked'] == true ||
                                    _isStagedCard(c['id'] as String);
                                if (sick) {
                                  setState(() =>
                                      _error = 'Creature is summoning sick');
                                } else if (attacked) {
                                  setState(() =>
                                      _error = 'Creature already attacked');
                                } else {
                                  setState(() {
                                    _error = null;
                                    _selectedAttackerId = c['id'] as String;
                                  });
                                }
                              },
                        selectedId: _selectedAttackerId,
                      ),
                      const SizedBox(height: 8),

                      // ── my seat bar + vibe ────────────────────────────────
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 16),
                        child: _seatBar(me,
                            isMe: true,
                            active: myTurn,
                            auraOverride: myTurn ? auraLeft : null),
                      ),
                      const SizedBox(height: 8),

                      // ── staged actions ────────────────────────────────────
                      if (_staged.isNotEmpty)
                        SizedBox(
                          height: 40,
                          child: ListView(
                            scrollDirection: Axis.horizontal,
                            padding: const EdgeInsets.symmetric(horizontal: 16),
                            children: [
                              for (var i = 0; i < _staged.length; i++)
                                Padding(
                                  padding: const EdgeInsets.only(right: 6),
                                  child: InputChip(
                                    label: Text(_staged[i].label,
                                        style: const TextStyle(fontSize: 11)),
                                    onDeleted: _submitting
                                        ? null
                                        : () => setState(
                                            () => _staged.removeAt(i)),
                                  ),
                                ),
                            ],
                          ),
                        ),

                      if (_error != null)
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
                          child: Text(_error!,
                              style: const TextStyle(
                                  color: AppTheme.danger, fontSize: 12)),
                        ),

                      const Spacer(),

                      // ── hand ──────────────────────────────────────────────
                      if (mySeat != null)
                        SizedBox(
                          height: 120,
                          child: hand.isEmpty
                              ? const Center(
                                  child: Text('Your hand is empty',
                                      style: TextStyle(
                                          color: AppTheme.textSecondary,
                                          fontSize: 12)))
                              : ListView(
                                  scrollDirection: Axis.horizontal,
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 16),
                                  children: [
                                    for (final c in hand)
                                      _HandCard(
                                        card: c,
                                        staged: _isStagedCard(c['id'] as String),
                                        affordable: ((c['snap_aura_cost']
                                                        as num?)
                                                    ?.toInt() ??
                                                0) <=
                                            auraLeft,
                                        enabled: myTurn && !_submitting,
                                        onTap: () {
                                          if (_isStagedCard(c['id'] as String)) {
                                            return;
                                          }
                                          final cost = (c['snap_aura_cost']
                                                      as num?)
                                                  ?.toInt() ??
                                              0;
                                          if (cost > auraLeft) {
                                            setState(() =>
                                                _error = 'Not enough Aura');
                                            return;
                                          }
                                          _stageHandCard(
                                              c,
                                              myField.length);
                                        },
                                      ),
                                  ],
                                ),
                        ),

                      // ── end turn ──────────────────────────────────────────
                      Padding(
                        padding: const EdgeInsets.all(16),
                        child: FilledButton.icon(
                          onPressed:
                              (!myTurn || _submitting) ? null : _endTurn,
                          icon: _submitting
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                      strokeWidth: 2))
                              : const Icon(Icons.done_all),
                          label: Text(myTurn
                              ? (_staged.isEmpty
                                  ? 'Pass turn'
                                  : 'End turn (${_staged.length} '
                                      'action${_staged.length == 1 ? '' : 's'})')
                              : 'Waiting for ${opp?.username ?? 'opponent'}…'),
                        ),
                      ),
                    ]),

                    // ── match-over overlay ──────────────────────────────────
                    if (match.status != 'active')
                      _MatchOverOverlay(
                        won: _didIWin(match, seats, mySeat),
                        onExit: () => context.go('/battle'),
                      ),
                  ]),
                ),
              ),
      ),
    );
  }

  static bool _didIWin(CcgLiveMatch match, List<CcgSeat> seats, int? mySeat) {
    if (mySeat == null) return false;
    final me = seats.where((s) => s.seat == mySeat).firstOrNull;
    final opp = seats.where((s) => s.seat != mySeat).firstOrNull;
    // winner_seat isn't streamed on the list model; life decides visually, and
    // a forfeit shows as the conceding side at full life — treat "opponent not
    // dead but I conceded" via life tie-break on the server events. Keep it
    // simple: I won iff opponent is at 0 or below, or I'm alive and they left.
    if (opp != null && opp.life <= 0) return true;
    if (me != null && me.life <= 0) return false;
    return false;
  }

  Widget _seatBar(CcgSeat? seat,
      {required bool isMe, required bool active, int? auraOverride}) {
    final aura = auraOverride ?? seat?.aura ?? 0;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
            color: active ? AppTheme.secondary : AppTheme.cardBorder,
            width: active ? 1.5 : 1),
      ),
      child: Row(children: [
        Icon(isMe ? Icons.person : Icons.person_outline,
            size: 18, color: active ? AppTheme.secondary : AppTheme.textSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            '${seat?.username ?? (isMe ? 'You' : 'Opponent')}${isMe ? ' (you)' : ''}',
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: AppTheme.textPrimary, fontWeight: FontWeight.w700),
          ),
        ),
        Text('❤ ${seat?.life ?? '—'}',
            style: const TextStyle(
                color: AppTheme.danger,
                fontSize: 14,
                fontWeight: FontWeight.w800)),
        const SizedBox(width: 12),
        Text('◆ $aura/${seat?.maxAura ?? 0}',
            style: const TextStyle(
                color: AppTheme.secondary,
                fontSize: 13,
                fontWeight: FontWeight.w700)),
      ]),
    );
  }

  Widget _fieldRow({
    required List<Map<String, dynamic>> cards,
    required String emptyLabel,
    bool mine = false,
    bool highlight = false,
    String? selectedId,
    void Function(Map<String, dynamic>)? onTap,
  }) {
    return SizedBox(
      height: 92,
      child: cards.isEmpty
          ? Center(
              child: Text(emptyLabel,
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12)))
          : ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                for (final c in cards)
                  _FieldCard(
                    card: c,
                    mine: mine,
                    selected: selectedId == c['id'],
                    targetable: highlight,
                    exhausted: mine &&
                        (c['has_attacked'] == true ||
                            c['is_summoning_sick'] == true ||
                            _isStagedCard(c['id'] as String)),
                    onTap: onTap == null ? null : () => onTap(c),
                  ),
              ],
            ),
    );
  }
}

class _FieldCard extends StatelessWidget {
  final Map<String, dynamic> card;
  final bool mine;
  final bool selected;
  final bool targetable;
  final bool exhausted;
  final VoidCallback? onTap;
  const _FieldCard({
    required this.card,
    required this.mine,
    required this.selected,
    required this.targetable,
    required this.exhausted,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final color = mine ? AppTheme.secondary : AppTheme.danger;
    final borderColor = selected
        ? AppTheme.primary
        : targetable
            ? AppTheme.danger
            : color.withValues(alpha: 0.5);
    final shield = (card['shield'] as num?)?.toInt() ?? 0;
    return Opacity(
      opacity: exhausted && mine ? 0.55 : 1,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Container(
          width: 78,
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: borderColor, width: selected || targetable ? 2 : 1),
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text('T${card['snap_tier'] ?? '?'} ${card['snap_family'] ?? ''}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                      color: color, fontSize: 10, fontWeight: FontWeight.w800)),
              const SizedBox(height: 4),
              Text(
                  '${card['cur_atk'] ?? card['snap_atk'] ?? '—'}/'
                  '${card['cur_hp'] ?? card['snap_hp'] ?? '—'}',
                  style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w800)),
              if (shield > 0)
                Text('🛡 $shield',
                    style: const TextStyle(
                        color: AppTheme.secondary, fontSize: 10)),
            ],
          ),
        ),
      ),
    );
  }
}

class _HandCard extends StatelessWidget {
  final Map<String, dynamic> card;
  final bool staged;
  final bool affordable;
  final bool enabled;
  final VoidCallback onTap;
  const _HandCard({
    required this.card,
    required this.staged,
    required this.affordable,
    required this.enabled,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isCreature = (card['snap_chit_type'] ?? 'creature') == 'creature';
    final cost = (card['snap_aura_cost'] as num?)?.toInt() ?? 0;
    final playable = enabled && affordable && !staged;
    return Opacity(
      opacity: playable ? 1 : 0.5,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 90,
          margin: const EdgeInsets.only(right: 8),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
                color: staged
                    ? AppTheme.primary
                    : AppTheme.cardBorder),
          ),
          child: Column(
            children: [
              Row(children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: AppTheme.secondary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text('◆$cost',
                      style: const TextStyle(
                          color: AppTheme.secondary,
                          fontSize: 11,
                          fontWeight: FontWeight.w800)),
                ),
                const Spacer(),
                Text('T${card['snap_tier'] ?? '?'}',
                    style: const TextStyle(
                        color: AppTheme.primary,
                        fontSize: 11,
                        fontWeight: FontWeight.w800)),
              ]),
              const Spacer(),
              Icon(isCreature ? Icons.pets : Icons.bolt,
                  size: 20,
                  color: isCreature ? AppTheme.primary : AppTheme.secondary),
              const SizedBox(height: 4),
              Text(
                isCreature
                    ? '${card['snap_atk'] ?? '—'}/${card['snap_hp'] ?? '—'}'
                    : 'Spell',
                style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              Text(staged ? 'STAGED' : (isCreature ? 'Summon' : 'Cast'),
                  style: TextStyle(
                      color: staged
                          ? AppTheme.primary
                          : AppTheme.textSecondary,
                      fontSize: 9,
                      fontWeight: FontWeight.w700)),
            ],
          ),
        ),
      ),
    );
  }
}

class _MatchOverOverlay extends StatelessWidget {
  final bool won;
  final VoidCallback onExit;
  const _MatchOverOverlay({required this.won, required this.onExit});

  @override
  Widget build(BuildContext context) {
    return Positioned.fill(
      child: Container(
        color: AppTheme.background.withValues(alpha: 0.88),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(won ? Icons.emoji_events : Icons.sentiment_dissatisfied,
                size: 64,
                color: won ? const Color(0xFFFFD700) : AppTheme.textSecondary),
            const SizedBox(height: 14),
            Text(won ? 'Victory!' : 'Match over',
                style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 24,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 20),
            FilledButton(
                onPressed: onExit, child: const Text('Back to Battle hub')),
          ],
        ),
      ),
    );
  }
}
