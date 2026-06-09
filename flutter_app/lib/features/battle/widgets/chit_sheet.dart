import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/widgets/n_tappable.dart';
import '../models/battle_models.dart';
import '../providers/battle_providers.dart';

/// Battle Chit inventory sheet.
///
/// When [matchId] and [participantId] are non-null (a live match), tapping a chit
/// uses it via `battle_use_chit`. Chits whose `requiresTarget` is true prompt for a
/// target ([opponents] for opponent-facing chits, [allies] bench for wild_card).
/// When the live context is absent (e.g. the placeholder combat screen) the sheet
/// previews the inventory read-only.
class ChitSheet extends ConsumerStatefulWidget {
  final String? matchId;
  final String? participantId;
  final List<BattleParticipant> opponents;
  final List<BattleParticipant> allies;

  const ChitSheet({
    super.key,
    this.matchId,
    this.participantId,
    this.opponents = const [],
    this.allies = const [],
  });

  @override
  ConsumerState<ChitSheet> createState() => _ChitSheetState();
}

class _ChitSheetState extends ConsumerState<ChitSheet> {
  ChitInventoryItem? _pendingTarget; // chit awaiting a target pick
  bool _busy = false;
  String? _error;

  bool get _live => widget.matchId != null && widget.participantId != null;

  Color _rarityColor(String rarity) {
    switch (rarity) {
      case 'uncommon':
        return const Color(0xFF03DAC6);
      case 'rare':
        return const Color(0xFF42A5F5);
      case 'epic':
        return const Color(0xFF9C5BFF);
      case 'legendary':
        return const Color(0xFFFFB300);
      case 'mythic':
        return const Color(0xFFFF4757);
      default:
        return Colors.white60;
    }
  }

  Future<void> _use(ChitInventoryItem chit, {String? targetParticipantId}) async {
    if (!_live) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(useChitProvider).call(
            matchId: widget.matchId!,
            participantId: widget.participantId!,
            chitDefinitionId: chit.chitDefinitionId,
            targetParticipantId: targetParticipantId,
          );
      ref.invalidate(chitInventoryProvider);
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _friendly(e.toString());
        });
      }
    }
  }

  String _friendly(String raw) {
    if (raw.contains('one chit may be used per turn')) {
      return 'Only one chit per turn.';
    }
    if (raw.contains('prediction-market stake')) {
      return 'You have a bet on this match — players with a stake can\'t use chits.';
    }
    if (raw.contains('per match')) return 'That chit is used up for this match.';
    return 'Could not use chit. Try again.';
  }

  void _onTapChit(ChitInventoryItem chit) {
    if (!_live) return;
    if (chit.requiresTarget) {
      setState(() => _pendingTarget = chit);
    } else {
      _use(chit);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_pendingTarget != null) return _buildTargetStep(_pendingTarget!);
    return _buildList();
  }

  Widget _buildList() {
    final inventory = ref.watch(chitInventoryProvider);
    return _frame(
      child: inventory.when(
        loading: () => const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator(color: Color(0xFFFFB300))),
        ),
        error: (_, __) => const Padding(
          padding: EdgeInsets.all(20),
          child: Text('Could not load chits.',
              style: TextStyle(color: Colors.white54)),
        ),
        data: (chits) {
          if (chits.isEmpty) {
            return const Padding(
              padding: EdgeInsets.fromLTRB(0, 8, 0, 8),
              child: Text(
                'No chits collected yet.\nEarn chits through challenges, packs, and match wins.',
                style: TextStyle(color: Colors.white54, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            );
          }
          return Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!_live)
                const Padding(
                  padding: EdgeInsets.only(bottom: 12),
                  child: Text('Usable in live matches.',
                      style: TextStyle(color: Colors.white38, fontSize: 12)),
                ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Text(_error!,
                      style: const TextStyle(color: Color(0xFFFF4757), fontSize: 12)),
                ),
              ...chits.map(_chitRow),
            ],
          );
        },
      ),
    );
  }

  Widget _chitRow(ChitInventoryItem chit) {
    final color = _rarityColor(chit.rarity);
    return NTappable(
      onTap: (_live && !_busy) ? () => _onTapChit(chit) : null,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: const Color(0xFF12121E),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Row(
          children: [
            Container(
              width: 8,
              height: 8,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(chit.name,
                      style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(chit.description,
                      style: const TextStyle(color: Colors.white54, fontSize: 11)),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text('×${chit.quantity}',
                style: TextStyle(
                    color: color, fontSize: 13, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _buildTargetStep(ChitInventoryItem chit) {
    final isWildCard = chit.effectType == 'wild_card';
    final targets = isWildCard
        ? widget.allies.where((a) => !a.isFainted).toList()
        : widget.opponents.where((o) => !o.isFainted).toList();
    return _frame(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: _busy ? null : () => setState(() => _pendingTarget = null),
                icon: const Icon(Icons.arrow_back, color: Colors.white54, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  isWildCard ? 'Swap in…' : 'Choose target',
                  style: const TextStyle(
                      color: Colors.white, fontSize: 15, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (targets.isEmpty)
            const Padding(
              padding: EdgeInsets.all(12),
              child: Text('No valid target.',
                  style: TextStyle(color: Colors.white54, fontSize: 13)),
            )
          else
            ...targets.map((t) => NTappable(
                  onTap: _busy ? null : () => _use(chit, targetParticipantId: t.id),
                  child: Container(
                    margin: const EdgeInsets.only(bottom: 8),
                    padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
                    decoration: BoxDecoration(
                      color: const Color(0xFF12121E),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(t.characterName,
                              style: const TextStyle(
                                  color: Colors.white, fontSize: 14)),
                        ),
                        Text('${t.currentHp}/${t.maxHp} HP',
                            style: const TextStyle(
                                color: Colors.white38, fontSize: 12)),
                      ],
                    ),
                  ),
                )),
        ],
      ),
    );
  }

  Widget _frame({required Widget child}) {
    return Container(
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
              width: 36,
              height: 4,
              decoration: BoxDecoration(
                  color: Colors.white24, borderRadius: BorderRadius.circular(2)),
            ),
          ),
          const SizedBox(height: 16),
          const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.style_rounded, color: Color(0xFFFFB300), size: 22),
              SizedBox(width: 8),
              Text('Battle Chits',
                  style: TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold)),
            ],
          ),
          const SizedBox(height: 16),
          child,
        ],
      ),
    );
  }
}
