import 'package:flutter/material.dart';

class BattleHud extends StatelessWidget {
  final String playerArchetype;
  final int playerHp;
  final int playerMaxHp;
  final int playerAp;
  final int playerMaxAp;
  final String opponentArchetype;
  final int opponentHp;
  final int opponentMaxHp;
  final int turnSecondsLeft;

  const BattleHud({
    super.key,
    required this.playerArchetype,
    required this.playerHp,
    required this.playerMaxHp,
    required this.playerAp,
    required this.playerMaxAp,
    required this.opponentArchetype,
    required this.opponentHp,
    required this.opponentMaxHp,
    required this.turnSecondsLeft,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 10),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.72),
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: _CharCard(
              archetype: playerArchetype,
              hp: playerHp,
              maxHp: playerMaxHp,
              ap: playerAp,
              maxAp: playerMaxAp,
              isPlayer: true,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: _TimerPill(seconds: turnSecondsLeft),
          ),
          Expanded(
            child: _CharCard(
              archetype: opponentArchetype,
              hp: opponentHp,
              maxHp: opponentMaxHp,
              isPlayer: false,
            ),
          ),
        ],
      ),
    );
  }
}

class _CharCard extends StatelessWidget {
  final String archetype;
  final int hp;
  final int maxHp;
  final int? ap;
  final int? maxAp;
  final bool isPlayer;

  const _CharCard({
    required this.archetype,
    required this.hp,
    required this.maxHp,
    this.ap,
    this.maxAp,
    required this.isPlayer,
  });

  Color _hpColor(double pct) {
    if (pct > 0.5) return const Color(0xFF00C896);
    if (pct > 0.25) return Colors.orange;
    return const Color(0xFFFF4757);
  }

  @override
  Widget build(BuildContext context) {
    final hpPct = (hp / maxHp).clamp(0.0, 1.0);
    final label = archetype[0].toUpperCase() + archetype.substring(1);

    return Column(
      crossAxisAlignment:
          isPlayer ? CrossAxisAlignment.start : CrossAxisAlignment.end,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 11,
            fontWeight: FontWeight.bold,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 5),
        Row(
          children: [
            if (!isPlayer) ...[
              Text(
                '$hp/$maxHp',
                style: const TextStyle(color: Colors.white54, fontSize: 10),
              ),
              const SizedBox(width: 6),
            ],
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(3),
                child: LinearProgressIndicator(
                  value: hpPct,
                  backgroundColor: Colors.white12,
                  valueColor: AlwaysStoppedAnimation(_hpColor(hpPct)),
                  minHeight: 7,
                ),
              ),
            ),
            if (isPlayer) ...[
              const SizedBox(width: 6),
              Text(
                '$hp/$maxHp',
                style: const TextStyle(color: Colors.white54, fontSize: 10),
              ),
            ],
          ],
        ),
        if (isPlayer && ap != null && maxAp != null) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: (ap! / maxAp!).clamp(0.0, 1.0),
                    backgroundColor: Colors.white12,
                    valueColor:
                        const AlwaysStoppedAnimation(Color(0xFF6C63FF)),
                    minHeight: 5,
                  ),
                ),
              ),
              const SizedBox(width: 6),
              Text(
                '$ap AP',
                style: const TextStyle(
                  color: Color(0xFF6C63FF),
                  fontSize: 10,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _TimerPill extends StatelessWidget {
  final int seconds;

  const _TimerPill({required this.seconds});

  Color get _color {
    if (seconds > 10) return const Color(0xFF00C896);
    if (seconds > 5) return Colors.orange;
    return const Color(0xFFFF4757);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 400),
      width: 44,
      height: 44,
      decoration: BoxDecoration(
        color: _color.withValues(alpha: 0.15),
        shape: BoxShape.circle,
        border: Border.all(color: _color.withValues(alpha: 0.7), width: 1.5),
      ),
      alignment: Alignment.center,
      child: Text(
        '$seconds',
        style: TextStyle(
          color: _color,
          fontSize: 17,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}
