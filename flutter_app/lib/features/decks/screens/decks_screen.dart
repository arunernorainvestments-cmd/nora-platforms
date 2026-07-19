import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/n_back_button.dart';
import '../../battle/providers/matchmaking_providers.dart';
import '../providers/deck_providers.dart';

/// Deck manager — the missing surface over migration 118. Lists the user's
/// decks with live legality, creates/renames/deletes, and opens the editor.
/// A legal 20-card deck is the entry ticket to /battle/find.
class DecksScreen extends ConsumerStatefulWidget {
  const DecksScreen({super.key});

  @override
  ConsumerState<DecksScreen> createState() => _DecksScreenState();
}

class _DecksScreenState extends ConsumerState<DecksScreen> {
  bool _busy = false;

  Future<void> _createDeck() async {
    final controller = TextEditingController(text: 'New Deck');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Name your deck',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 17)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          style: const TextStyle(color: AppTheme.textPrimary),
          decoration: const InputDecoration(hintText: 'e.g. Aggro Athletes'),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(controller.text),
            child: const Text('Create'),
          ),
        ],
      ),
    );
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty) return;
    setState(() => _busy = true);
    try {
      final deckId = await DeckService.create(trimmed);
      ref.invalidate(myDecksProvider);
      if (mounted) context.push('/decks/$deckId');
    } catch (e) {
      _snack(_friendly(e), danger: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _quickBuild() async {
    setState(() => _busy = true);
    try {
      final deckId = await quickBuildDeck();
      ref.invalidate(myDecksProvider);
      _snack('Quick Deck built from your strongest 20 cards.');
      if (mounted) context.push('/decks/$deckId');
    } catch (e) {
      _snack(_friendly(e), danger: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _deleteDeck(MyDeck deck) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Delete this deck?',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 17)),
        content: Text(
          '"${deck.name}" will be deleted. Your cards are untouched — a deck '
          'is just a lineup.',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    setState(() => _busy = true);
    try {
      await DeckService.delete(deck.id);
      ref.invalidate(myDecksProvider);
    } catch (e) {
      _snack(_friendly(e), danger: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _snack(String msg, {bool danger = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(msg),
        backgroundColor: danger ? AppTheme.danger : AppTheme.surface));
  }

  String _friendly(Object e) {
    final s = e.toString();
    if (s.contains('duplicate key')) {
      return 'You already have a deck with that name.';
    }
    final m = RegExp(r'Exception: (.*)$').firstMatch(s);
    return m?.group(1) ?? 'Something went wrong. Try again.';
  }

  @override
  Widget build(BuildContext context) {
    final decksAsync = ref.watch(myDecksProvider);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: const NBackButton(fallback: '/battle'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('My Decks', style: TextStyle(color: Colors.white)),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: decksAsync.when(
              loading: () => const Center(
                  child: CircularProgressIndicator(color: AppTheme.primary)),
              error: (e, _) => Center(
                child: Text('Could not load decks: $e',
                    style:
                        const TextStyle(color: AppTheme.danger, fontSize: 13)),
              ),
              data: (decks) => ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  const Text(
                    'A battle deck is exactly 20 cards, max 2 copies of any '
                    'BattleChit. Legality is checked on every save and again '
                    'at match entry.',
                    style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 13,
                        height: 1.5),
                  ),
                  const SizedBox(height: 16),
                  for (final d in decks) _deckTile(d),
                  if (decks.isEmpty)
                    Container(
                      padding: const EdgeInsets.symmetric(vertical: 36),
                      decoration: BoxDecoration(
                        color: AppTheme.surface,
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(color: AppTheme.cardBorder),
                      ),
                      child: const Column(children: [
                        Icon(Icons.style_outlined,
                            size: 40, color: AppTheme.textSecondary),
                        SizedBox(height: 12),
                        Text('No decks yet',
                            style: TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.w600)),
                        SizedBox(height: 4),
                        Text(
                            'Build one by hand, or quick-build from your '
                            'strongest cards.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: AppTheme.textSecondary, fontSize: 12)),
                      ]),
                    ),
                  const SizedBox(height: 16),
                  FilledButton.icon(
                    onPressed: _busy ? null : _createDeck,
                    icon: const Icon(Icons.add),
                    label: const Text('New deck'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : _quickBuild,
                    icon: const Icon(Icons.auto_fix_high_outlined, size: 18),
                    label: const Text('Quick-build from my best cards'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => context.push('/battle/find'),
                    icon: const Icon(Icons.sports_kabaddi, size: 18),
                    label: const Text('Find a match'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _deckTile(MyDeck d) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => context.push('/decks/${d.id}'),
        borderRadius: BorderRadius.circular(12),
        child: Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.cardBorder),
          ),
          child: Row(children: [
            const Icon(Icons.style_outlined,
                size: 20, color: AppTheme.primary),
            const SizedBox(width: 12),
            Expanded(
              child: Text(d.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontWeight: FontWeight.w600)),
            ),
            Text('${d.cardCount}/20',
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 12)),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: (d.isLegal ? AppTheme.success : AppTheme.danger)
                    .withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(20),
              ),
              child: Text(d.isLegal ? 'LEGAL' : 'NOT LEGAL',
                  style: TextStyle(
                      color: d.isLegal ? AppTheme.success : AppTheme.danger,
                      fontSize: 9,
                      fontWeight: FontWeight.w800)),
            ),
            IconButton(
              tooltip: 'Delete deck',
              onPressed: _busy ? null : () => _deleteDeck(d),
              icon: const Icon(Icons.delete_outline,
                  size: 18, color: AppTheme.textSecondary),
            ),
          ]),
        ),
      ),
    );
  }
}
