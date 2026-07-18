import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/spectate_providers.dart';
import '../../../core/widgets/n_back_button.dart';

/// Live spectator view of a NORA Arena (mobile) card-battler match.
/// Everything shown here is the server-authoritative state (migration 147
/// spectator read path): seats + life/aura, the shared Vibe meter, the board,
/// and the ordered event feed. Read-only by design — spectators influence
/// nothing (Hard Rule 26 stays with the bet RPCs).
class BattleSpectateScreen extends ConsumerWidget {
  final String matchId;
  const BattleSpectateScreen({super.key, required this.matchId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final matchAsync = ref.watch(ccgMatchStreamProvider(matchId));
    final seats = ref.watch(ccgSeatsStreamProvider(matchId)).valueOrNull ?? [];
    final events = ref.watch(ccgEventsStreamProvider(matchId)).valueOrNull ?? [];
    final board = ref.watch(ccgBoardStreamProvider(matchId)).valueOrNull ?? [];

    final match = matchAsync.valueOrNull;
    final p1 = seats.where((s) => s.seat == 1).firstOrNull;
    final p2 = seats.where((s) => s.seat == 2).firstOrNull;

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: const NBackButton(fallback: '/battle'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: Row(children: [
          const Text('Spectating', style: TextStyle(color: Colors.white)),
          const SizedBox(width: 10),
          if (match != null && match.status == 'active')
            const Icon(Icons.circle, color: AppTheme.danger, size: 10),
        ]),
      ),
      body: SafeArea(
        child: matchAsync.when(
          loading: () => const Center(
              child: CircularProgressIndicator(color: AppTheme.primary)),
          error: (e, _) => Center(
              child: Text('Could not load match: $e',
                  style: const TextStyle(color: AppTheme.danger))),
          data: (m) {
            if (m == null) {
              return const Center(
                  child: Text('Match not found',
                      style: TextStyle(color: AppTheme.textSecondary)));
            }
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(children: [
                  // ── Header: seats + life/aura, turn, vibe ────────────────
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                    child: Column(children: [
                      Row(children: [
                        Expanded(
                            child: _SeatPanel(
                                seat: p1,
                                fallback: 'Player 1',
                                active: m.activeSeat == 1)),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 12),
                          child: Column(children: [
                            Text(
                              m.status == 'finished'
                                  ? 'FINAL'
                                  : 'TURN ${m.turnNumber}',
                              style: const TextStyle(
                                  color: AppTheme.textSecondary,
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  letterSpacing: 1),
                            ),
                            const SizedBox(height: 4),
                            const Text('VS',
                                style: TextStyle(
                                    color: AppTheme.primary,
                                    fontSize: 18,
                                    fontWeight: FontWeight.w900)),
                          ]),
                        ),
                        Expanded(
                            child: _SeatPanel(
                                seat: p2,
                                fallback: 'Player 2',
                                active: m.activeSeat == 2,
                                alignEnd: true)),
                      ]),
                      const SizedBox(height: 12),
                      _VibeMeter(vibe: m.currentVibe),
                      if (m.status == 'finished') ...[
                        const SizedBox(height: 10),
                        Text(
                          '🏆 ${(m.status == 'finished' && seats.isNotEmpty) ? _winnerName(m, p1, p2) : ''}',
                          style: const TextStyle(
                              color: Color(0xFFFFD700),
                              fontSize: 14,
                              fontWeight: FontWeight.w800),
                        ),
                      ],
                    ]),
                  ),
                  const SizedBox(height: 12),

                  // ── Board (field creatures only — spectator-visible zone) ─
                  if (board.isNotEmpty)
                    SizedBox(
                      height: 84,
                      child: ListView(
                        scrollDirection: Axis.horizontal,
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        children:
                            board.map((c) => _BoardCard(card: c)).toList(),
                      ),
                    ),
                  if (board.isNotEmpty) const SizedBox(height: 8),
                  const Divider(color: AppTheme.cardBorder, height: 1),

                  // ── Live event feed (newest first) ───────────────────────
                  Expanded(
                    child: ListView.builder(
                      reverse: true,
                      padding: const EdgeInsets.all(16),
                      itemCount: events.length,
                      itemBuilder: (context, i) {
                        final e = events[events.length - 1 - i];
                        return _EventRow(event: e, p1: p1, p2: p2);
                      },
                    ),
                  ),
                ]),
              ),
            );
          },
        ),
      ),
    );
  }

  static String _winnerName(CcgLiveMatch m, CcgSeat? p1, CcgSeat? p2) {
    final l1 = p1?.life ?? 0;
    final l2 = p2?.life ?? 0;
    if (l1 <= 0 && l2 > 0) return '${p2?.username ?? 'Player 2'} wins';
    if (l2 <= 0 && l1 > 0) return '${p1?.username ?? 'Player 1'} wins';
    return 'Match over';
  }
}

class _SeatPanel extends StatelessWidget {
  final CcgSeat? seat;
  final String fallback;
  final bool active;
  final bool alignEnd;
  const _SeatPanel({
    required this.seat,
    required this.fallback,
    required this.active,
    this.alignEnd = false,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: active ? AppTheme.secondary : AppTheme.cardBorder,
          width: active ? 1.5 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment:
            alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          Text(seat?.username ?? fallback,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text('❤ ${seat?.life ?? '—'}',
              style: const TextStyle(
                  color: AppTheme.danger,
                  fontSize: 16,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 2),
          Text('Aura ${seat?.aura ?? 0}/${seat?.maxAura ?? 0}',
              style:
                  const TextStyle(color: AppTheme.secondary, fontSize: 12)),
        ],
      ),
    );
  }
}

class _VibeMeter extends StatelessWidget {
  final int vibe;
  const _VibeMeter({required this.vibe});

  @override
  Widget build(BuildContext context) {
    return Row(children: [
      const Text('VIBE',
          style: TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 10,
              fontWeight: FontWeight.w700,
              letterSpacing: 1)),
      const SizedBox(width: 8),
      Expanded(
        child: ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: vibe / 100,
            minHeight: 8,
            backgroundColor: AppTheme.cardBorder,
            valueColor: const AlwaysStoppedAnimation<Color>(AppTheme.primary),
          ),
        ),
      ),
      const SizedBox(width: 8),
      Text('$vibe',
          style: const TextStyle(
              color: AppTheme.primary,
              fontSize: 12,
              fontWeight: FontWeight.w700)),
    ]);
  }
}

class _BoardCard extends StatelessWidget {
  final Map<String, dynamic> card;
  const _BoardCard({required this.card});

  @override
  Widget build(BuildContext context) {
    final tier = card['snap_tier'] as String? ?? '?';
    final atk = card['cur_atk'] ?? card['snap_atk'];
    final hp = card['cur_hp'] ?? card['snap_hp'];
    final seat = (card['owner_seat'] as num?)?.toInt() ?? 1;
    final color = seat == 1 ? AppTheme.primary : AppTheme.secondary;

    return Container(
      width: 72,
      margin: const EdgeInsets.only(right: 8),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('T$tier',
              style: TextStyle(
                  color: color, fontSize: 12, fontWeight: FontWeight.w800)),
          const SizedBox(height: 4),
          Text('${atk ?? '—'}/${hp ?? '—'}',
              style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w700)),
          Text('P$seat',
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 9)),
        ],
      ),
    );
  }
}

class _EventRow extends StatelessWidget {
  final CcgEvent event;
  final CcgSeat? p1;
  final CcgSeat? p2;
  const _EventRow({required this.event, required this.p1, required this.p2});

  String get _actor => event.actorSeat == 1
      ? (p1?.username ?? 'Player 1')
      : event.actorSeat == 2
          ? (p2?.username ?? 'Player 2')
          : 'Match';

  (IconData, Color, String) get _display => switch (event.eventType) {
        'match_start' => (Icons.flag, AppTheme.success, 'Match started'),
        'turn_start' => (
            Icons.replay,
            AppTheme.textSecondary,
            '$_actor begins turn ${event.turnNumber}'
          ),
        'draw' => (Icons.style, AppTheme.textSecondary, '$_actor draws a card'),
        'summon' => (
            Icons.auto_awesome,
            AppTheme.primary,
            '$_actor summons a creature'
          ),
        'cast' => (Icons.bolt, AppTheme.primary, '$_actor casts a spell-moment'),
        'activate' => (
            Icons.flare,
            AppTheme.primary,
            '$_actor activates an ability'
          ),
        'attack' => (Icons.sports_mma, AppTheme.danger, '$_actor attacks'),
        'fusion' => (
            Icons.merge_type,
            const Color(0xFFFFD700),
            '$_actor performs a FUSION!'
          ),
        // Wave-1 effect resolution (migs 151/152): payload carries
        // {kind, target, magnitude} from ccg_apply_effect.
        'effect' => (Icons.auto_fix_high, AppTheme.secondary, _effectText()),
        'ko' => (Icons.close, AppTheme.danger, 'A creature is destroyed'),
        'life_change' => (
            Icons.favorite,
            AppTheme.danger,
            _lifeText(),
          ),
        'aura_change' => (
            Icons.brightness_7,
            AppTheme.secondary,
            '$_actor\'s Aura changes'
          ),
        'vibe_change' => (
            Icons.equalizer,
            AppTheme.primary,
            'The crowd Vibe shifts to ${event.payload['vibe'] ?? ''}'
          ),
        'turn_end' => (
            Icons.hourglass_bottom,
            AppTheme.textSecondary,
            '$_actor ends the turn'
          ),
        'match_end' => (
            Icons.emoji_events,
            const Color(0xFFFFD700),
            'Match over!'
          ),
        _ => (Icons.circle, AppTheme.textSecondary, event.eventType),
      };

  /// Friendly line for an effect event, from the authored library's
  /// {kind, target, magnitude} vocabulary (unknown kinds still say something).
  String _effectText() {
    final kind = (event.payload['kind'] ?? '').toString();
    final target = (event.payload['target'] ?? '').toString();
    final mag = (event.payload['magnitude'] as num?)?.toInt();
    final n = mag == null ? '' : '$mag ';
    final who = switch (target) {
      'self' => 'itself',
      'ally_target' => 'an ally',
      'all_allies' => 'all allies',
      'enemy_target' => 'an enemy',
      'all_enemies' => 'all enemies',
      'enemy_face' => 'the opponent',
      _ => 'its target',
    };
    return switch (kind) {
      'direct_damage' => '$_actor\'s effect deals ${n}damage to $who',
      'aoe_damage' => '$_actor\'s effect blasts $who for ${n}damage',
      'heal' => '$_actor\'s effect heals $who for $n',
      'buff_atk' => '$_actor\'s effect gives $who +${n}ATK',
      'buff_hp' => '$_actor\'s effect gives $who +${n}HP',
      'buff_atk_hp' => '$_actor\'s effect gives $who +$n/+$n',
      'debuff_atk' => '$_actor\'s effect drains ${n}ATK from $who',
      'debuff_hp' => '$_actor\'s effect saps ${n}HP from $who',
      'shield_grant' => '$_actor\'s effect shields $who',
      'taunt_grant' => '$_actor\'s effect makes $who taunt',
      'removal' => '$_actor\'s effect destroys $who',
      'draw_card' => '$_actor\'s effect draws a card',
      'aura_refund' => '$_actor\'s effect refunds ${n}Aura',
      'disrupt_discard' => '$_actor\'s effect forces a discard',
      _ => '$_actor\'s ${kind.isEmpty ? 'effect' : kind.replaceAll('_', ' ')} '
          'resolves',
    };
  }

  String _lifeText() {
    final amount = (event.payload['amount'] as num?)?.toInt();
    if (amount == null) return '$_actor\'s Life changes';
    return amount < 0
        ? '$_actor loses ${-amount} Life'
        : '$_actor gains $amount Life';
  }

  @override
  Widget build(BuildContext context) {
    final (icon, color, text) = _display;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(children: [
        Container(
          width: 28,
          height: 28,
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            shape: BoxShape.circle,
          ),
          child: Icon(icon, color: color, size: 14),
        ),
        const SizedBox(width: 10),
        Expanded(
          child: Text(text,
              style:
                  const TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
        ),
        if (event.lifeP1After != null && event.lifeP2After != null)
          Text('${event.lifeP1After} · ${event.lifeP2After}',
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 11)),
      ]),
    );
  }
}
