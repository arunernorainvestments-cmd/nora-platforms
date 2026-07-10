import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../models/battle_models.dart';
import '../providers/battle_providers.dart';
import '../../../core/widgets/n_back_button.dart';

const _formats = [
  ('1v1', 'Duel', '2 players'),
  ('2v2', 'Skirmish', '4 players'),
  ('3v3', 'Squad', '6 players'),
];

class BattleMatchmakingScreen extends ConsumerStatefulWidget {
  const BattleMatchmakingScreen({super.key});

  @override
  ConsumerState<BattleMatchmakingScreen> createState() =>
      _BattleMatchmakingScreenState();
}

class _BattleMatchmakingScreenState
    extends ConsumerState<BattleMatchmakingScreen> {
  String _format = '1v1';
  String? _creatorId; // selected character
  bool _searching = false;
  String? _error;
  bool _navigated = false;

  Future<void> _findMatch() async {
    if (_creatorId == null) {
      setState(() => _error = 'Pick a character first');
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final matchId = await ref.read(battleMatchmakingProvider).enqueue(
            format: _format,
            creatorId: _creatorId!,
          );
      ref.invalidate(battleQueueCountsProvider);
      if (matchId != null && mounted) {
        _goToMatch(matchId);
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _searching = false;
          _error = 'Could not join the queue. Please try again.';
        });
      }
    }
  }

  Future<void> _cancel() async {
    try {
      await ref.read(battleMatchmakingProvider).leave();
    } catch (_) {}
    ref.invalidate(battleQueueCountsProvider);
    if (mounted) setState(() => _searching = false);
  }

  void _goToMatch(String matchId) {
    if (_navigated) return;
    _navigated = true;
    context.push('/battle/$matchId');
    // Reset so returning to this screen is clean.
    if (mounted) setState(() => _searching = false);
  }

  @override
  Widget build(BuildContext context) {
    // Navigate as soon as our queue row flips to 'matched'.
    ref.listen(myBattleQueueProvider, (_, next) {
      final row = next.valueOrNull;
      if (_searching &&
          row != null &&
          row['status'] == 'matched' &&
          row['matched_match_id'] != null) {
        _goToMatch(row['matched_match_id'] as String);
      }
    });

    final eligibleAsync = ref.watch(eligibleCharactersProvider);
    final counts = ref.watch(battleQueueCountsProvider).valueOrNull ?? const {};

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: const NBackButton(fallback: '/battle'),
        backgroundColor: AppTheme.surface,
        title: const Text('Quick Match',
            style: TextStyle(color: AppTheme.textPrimary)),
        iconTheme: const IconThemeData(color: AppTheme.textPrimary),
      ),
      body: SafeArea(
        child: eligibleAsync.when(
          loading: () =>
              const Center(child: CircularProgressIndicator(color: AppTheme.primary)),
          error: (_, __) => const Center(
            child: Text('Failed to load your characters',
                style: TextStyle(color: AppTheme.textSecondary)),
          ),
          data: (characters) {
            if (characters.isEmpty) return const _NoCharactersView();
            // Default selection.
            _creatorId ??= characters.first.creatorId;

            if (_searching) {
              return _SearchingView(
                format: _format,
                inQueue: counts[_format] ?? 0,
                onCancel: _cancel,
              );
            }

            return ListView(
              padding: const EdgeInsets.all(20),
              children: [
                const _Label('FORMAT'),
                const SizedBox(height: 10),
                Row(
                  children: _formats.map((f) {
                    final selected = _format == f.$1;
                    final n = counts[f.$1] ?? 0;
                    return Expanded(
                      child: Padding(
                        padding: EdgeInsets.only(right: f.$1 == '3v3' ? 0 : 8),
                        child: _FormatCard(
                          code: f.$1,
                          name: f.$2,
                          sub: f.$3,
                          inQueue: n,
                          selected: selected,
                          onTap: () => setState(() => _format = f.$1),
                        ),
                      ),
                    );
                  }).toList(),
                ),
                const SizedBox(height: 24),
                const _Label('YOUR CHARACTER'),
                const SizedBox(height: 10),
                ...characters.map((c) => _CharacterTile(
                      character: c,
                      selected: _creatorId == c.creatorId,
                      onTap: () => setState(() => _creatorId = c.creatorId),
                    )),
                const SizedBox(height: 24),
                if (_error != null) ...[
                  Text(_error!,
                      style: const TextStyle(
                          color: AppTheme.danger, fontSize: 13)),
                  const SizedBox(height: 12),
                ],
                FilledButton.icon(
                  onPressed: _findMatch,
                  icon: const Icon(Icons.bolt_rounded),
                  label: Text('Find $_format Match'),
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    foregroundColor: Colors.white,
                    minimumSize: const Size.fromHeight(52),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                    textStyle: const TextStyle(
                        fontSize: 16, fontWeight: FontWeight.w700),
                  ),
                ),
                const SizedBox(height: 12),
                const Text(
                  'When enough players queue for this format, the battle starts '
                  'automatically and opens a prediction market for spectators.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

// ─── Searching state ──────────────────────────────────────────────────────────

class _SearchingView extends StatelessWidget {
  final String format;
  final int inQueue;
  final VoidCallback onCancel;

  const _SearchingView({
    required this.format,
    required this.inQueue,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(color: AppTheme.primary),
          const SizedBox(height: 24),
          Text('Searching for a $format match…',
              style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Text('$inQueue in queue',
              style:
                  const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
          const SizedBox(height: 32),
          OutlinedButton(
            onPressed: onCancel,
            style: OutlinedButton.styleFrom(
              foregroundColor: AppTheme.textSecondary,
              side: const BorderSide(color: AppTheme.cardBorder),
            ),
            child: const Text('Cancel'),
          ),
        ],
      ),
    );
  }
}

// ─── No eligible characters ───────────────────────────────────────────────────

class _NoCharactersView extends StatelessWidget {
  const _NoCharactersView();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.style_outlined,
                size: 56, color: AppTheme.textSecondary),
            const SizedBox(height: 16),
            const Text('No characters to field yet',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text(
              'Buy a creator\'s likeness card to field their character in '
              'battle — or become a Market Maker to field yourself.',
              textAlign: TextAlign.center,
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () => context.push('/marketplace'),
              style: FilledButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
              ),
              child: const Text('Browse Likeness Cards'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Pieces ───────────────────────────────────────────────────────────────────

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
          color: AppTheme.textSecondary.withValues(alpha: 0.7),
          fontSize: 10,
          fontWeight: FontWeight.w700,
          letterSpacing: 1.2,
        ),
      );
}

class _FormatCard extends StatelessWidget {
  final String code;
  final String name;
  final String sub;
  final int inQueue;
  final bool selected;
  final VoidCallback onTap;

  const _FormatCard({
    required this.code,
    required this.name,
    required this.sub,
    required this.inQueue,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 8),
        decoration: BoxDecoration(
          color: selected
              ? AppTheme.primary.withValues(alpha: 0.15)
              : AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? AppTheme.primary : AppTheme.cardBorder,
            width: selected ? 2 : 1,
          ),
        ),
        child: Column(
          children: [
            Text(code,
                style: TextStyle(
                    color: selected ? AppTheme.primary : AppTheme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 2),
            Text(name,
                style: const TextStyle(
                    color: AppTheme.textPrimary, fontSize: 12, fontWeight: FontWeight.w600)),
            Text(sub,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 10)),
            const SizedBox(height: 4),
            Text(inQueue > 0 ? '$inQueue waiting' : '—',
                style: TextStyle(
                    color: inQueue > 0
                        ? AppTheme.secondary
                        : AppTheme.textSecondary.withValues(alpha: 0.5),
                    fontSize: 10,
                    fontWeight: FontWeight.w600)),
          ],
        ),
      ),
    );
  }
}

class _CharacterTile extends StatelessWidget {
  final EligibleCharacter character;
  final bool selected;
  final VoidCallback onTap;

  const _CharacterTile({
    required this.character,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final isSelf = character.eligibilityType == 'self';
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: selected
                ? AppTheme.primary.withValues(alpha: 0.12)
                : AppTheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: selected ? AppTheme.primary : AppTheme.cardBorder,
              width: selected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                clipBehavior: Clip.antiAlias,
                child: character.characterImageUrl != null
                    ? Image.network(character.characterImageUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const Icon(
                            Icons.person, color: AppTheme.primary, size: 22))
                    : const Icon(Icons.person,
                        color: AppTheme.primary, size: 22),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(character.characterName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 2),
                    Text(
                      '${character.archetype[0].toUpperCase()}${character.archetype.substring(1)}'
                      ' · ${isSelf ? 'You' : 'Card #${character.cardNumber ?? '—'}'}',
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (selected)
                const Icon(Icons.check_circle, color: AppTheme.primary, size: 20),
            ],
          ),
        ),
      ),
    );
  }
}
