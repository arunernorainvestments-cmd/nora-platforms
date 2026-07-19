import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/card_face.dart';
import '../../../core/widgets/n_back_button.dart';
import '../../battle/providers/matchmaking_providers.dart';
import '../providers/deck_providers.dart';

/// The deck editor: every owned BattleChit with a copy stepper, a live 20-card
/// counter and Aura curve, and one Save that hands the whole lineup to
/// deck_set_chits (the server is the only validator).
class DeckEditorScreen extends ConsumerStatefulWidget {
  const DeckEditorScreen({super.key, required this.deckId});

  final String deckId;

  @override
  ConsumerState<DeckEditorScreen> createState() => _DeckEditorScreenState();
}

class _DeckEditorScreenState extends ConsumerState<DeckEditorScreen> {
  /// chit_id → picked quantity. Seeded from the server once, then local until
  /// Save. Null until first data arrives.
  Map<String, int>? _counts;
  String _search = '';
  bool _saving = false;
  bool _dirty = false;
  List<String> _errors = const [];

  int get _total =>
      (_counts ?? const {}).values.fold(0, (sum, q) => sum + q);

  static const _tierColor = {
    'S': Color(0xFFFFD700),
    'A': Color(0xFFFF5A1F),
    'B': Color(0xFFB15CFF),
    'C': Color(0xFF03DAC6),
    'D': Color(0xFF00C896),
    'E': Color(0xFF8B8FA8),
    'F': Color(0xFF5A5E78),
  };

  Future<void> _save(DeckEditorData data) async {
    final counts = _counts;
    if (counts == null) return;
    setState(() {
      _saving = true;
      _errors = const [];
    });
    try {
      final res = await DeckService.save(widget.deckId, counts);
      final valid = res['is_valid'] == true;
      final errors = ((res['errors'] as List?) ?? const [])
          .map((e) => DeckService.friendlyError(e.toString()))
          .toList();
      ref.invalidate(myDecksProvider);
      if (!mounted) return;
      setState(() {
        _dirty = false;
        _errors = valid ? const [] : errors;
      });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(valid
            ? 'Deck saved — battle-legal. Time to find a match!'
            : 'Deck saved ($_total/20) — not battle-legal yet.'),
        backgroundColor: valid ? AppTheme.success : AppTheme.surface,
        action: valid
            ? SnackBarAction(
                label: 'Find a match',
                onPressed: () => context.push('/battle/find'))
            : null,
      ));
    } catch (e) {
      if (mounted) {
        setState(() => _errors = [
              RegExp(r'Exception: (.*)$').firstMatch(e.toString())?.group(1) ??
                  'Save failed — try again.'
            ]);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _rename(DeckEditorData data) async {
    final controller = TextEditingController(text: data.name);
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Rename deck',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 17)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLength: 40,
          style: const TextStyle(color: AppTheme.textPrimary),
          onSubmitted: (v) => Navigator.of(context).pop(v),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(controller.text),
              child: const Text('Rename')),
        ],
      ),
    );
    final trimmed = name?.trim() ?? '';
    if (trimmed.isEmpty || trimmed == data.name) return;
    try {
      await DeckService.rename(widget.deckId, trimmed);
      ref.invalidate(deckEditorProvider(widget.deckId));
      ref.invalidate(myDecksProvider);
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Rename failed — you may already have a deck with '
                'that name.'),
            backgroundColor: AppTheme.danger));
      }
    }
  }

  void _preview(DeckableChit c) {
    showDialog<void>(
      context: context,
      builder: (context) => Dialog(
        backgroundColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 360),
          child: CardFace(
            name: c.name,
            chitType: c.chitType,
            family: c.family,
            tier: c.tier,
            auraCost: c.auraCost,
            atk: c.atk,
            hp: c.hp,
            cardArtUrl: c.cardArtUrl,
            rulesText: c.rulesText,
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final dataAsync = ref.watch(deckEditorProvider(widget.deckId));

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: const NBackButton(fallback: '/decks'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: dataAsync.when(
          loading: () =>
              const Text('Deck', style: TextStyle(color: Colors.white)),
          error: (_, __) =>
              const Text('Deck', style: TextStyle(color: Colors.white)),
          data: (d) => InkWell(
            onTap: () => _rename(d),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Flexible(
                child: Text(d.name,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: Colors.white)),
              ),
              const SizedBox(width: 6),
              const Icon(Icons.edit_outlined,
                  size: 15, color: AppTheme.textSecondary),
            ]),
          ),
        ),
      ),
      body: SafeArea(
        child: dataAsync.when(
          loading: () => const Center(
              child: CircularProgressIndicator(color: AppTheme.primary)),
          error: (e, _) => Center(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text('Could not open this deck: $e',
                  style:
                      const TextStyle(color: AppTheme.danger, fontSize: 13)),
            ),
          ),
          data: (data) {
            _counts ??= Map<String, int>.from(data.savedCounts);
            return Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 640),
                child: Column(children: [
                  Expanded(child: _cardList(data)),
                  _bottomBar(data),
                ]),
              ),
            );
          },
        ),
      ),
    );
  }

  // ── card list ───────────────────────────────────────────────────────────────
  Widget _cardList(DeckEditorData data) {
    final query = _search.trim().toLowerCase();
    final visible = data.chits
        .where((c) => query.isEmpty || c.name.toLowerCase().contains(query))
        .toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 12),
      children: [
        TextField(
          onChanged: (v) => setState(() => _search = v),
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Search your cards…',
            hintStyle:
                const TextStyle(color: AppTheme.textSecondary, fontSize: 14),
            prefixIcon: const Icon(Icons.search,
                size: 18, color: AppTheme.textSecondary),
            isDense: true,
            filled: true,
            fillColor: AppTheme.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppTheme.cardBorder),
            ),
          ),
        ),
        const SizedBox(height: 12),
        _auraCurve(data),
        const SizedBox(height: 12),
        if (data.chits.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 16),
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.cardBorder),
            ),
            child: Column(children: [
              const Icon(Icons.style_outlined,
                  size: 40, color: AppTheme.textSecondary),
              const SizedBox(height: 12),
              const Text('No playable cards yet',
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              const Text(
                  'Mint a moment or pick up cards on the Chit Market, then '
                  'come back and build.',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
              const SizedBox(height: 12),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                OutlinedButton(
                    onPressed: () => context.push('/mint'),
                    child: const Text('Mint a moment')),
                const SizedBox(width: 10),
                OutlinedButton(
                    onPressed: () => context.push('/market'),
                    child: const Text('Chit Market')),
              ]),
            ]),
          ),
        for (final c in visible) _chitRow(c),
      ],
    );
  }

  Widget _chitRow(DeckableChit c) {
    final qty = _counts?[c.chitId] ?? 0;
    final cap = c.deckableCopies;
    final accent = CardFace.familyAccent[c.family.toLowerCase()] ??
        AppTheme.primary;

    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
              color: qty > 0
                  ? accent.withValues(alpha: 0.55)
                  : AppTheme.cardBorder),
        ),
        child: Row(children: [
          // Art thumbnail — tap for the full card face.
          InkWell(
            onTap: () => _preview(c),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              width: 44,
              height: 60,
              decoration: BoxDecoration(
                color: AppTheme.background,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: accent.withValues(alpha: 0.4)),
              ),
              clipBehavior: Clip.antiAlias,
              child: c.cardArtUrl != null
                  ? Image.network(c.cardArtUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => Icon(Icons.image_outlined,
                          size: 18, color: accent))
                  : Icon(Icons.auto_awesome, size: 18, color: accent),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(c.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Row(children: [
                _tierChip(c.tier),
                const SizedBox(width: 6),
                Icon(Icons.bolt, size: 12, color: accent),
                Text('${c.auraCost}',
                    style: TextStyle(
                        color: accent,
                        fontSize: 12,
                        fontWeight: FontWeight.w700)),
                const SizedBox(width: 8),
                if (c.chitType != 'spell_moment')
                  Text('${c.atk}/${c.hp}',
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 12))
                else
                  const Text('Spell',
                      style: TextStyle(
                          color: AppTheme.textSecondary, fontSize: 12)),
                const SizedBox(width: 8),
                Text('owns ${c.ownedCopies}',
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 11)),
              ]),
            ]),
          ),
          // Copy stepper: 0 → cap (owned copies, max 2).
          IconButton(
            onPressed: qty > 0
                ? () => setState(() {
                      _counts![c.chitId] = qty - 1;
                      _dirty = true;
                    })
                : null,
            icon: const Icon(Icons.remove_circle_outline, size: 20),
            color: AppTheme.textSecondary,
          ),
          SizedBox(
            width: 18,
            child: Text('$qty',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: qty > 0 ? accent : AppTheme.textSecondary,
                    fontSize: 15,
                    fontWeight: FontWeight.w800)),
          ),
          IconButton(
            onPressed: qty < cap && _total < 20
                ? () => setState(() {
                      _counts![c.chitId] = qty + 1;
                      _dirty = true;
                    })
                : null,
            icon: const Icon(Icons.add_circle_outline, size: 20),
            color: AppTheme.primary,
          ),
        ]),
      ),
    );
  }

  Widget _tierChip(String tier) {
    final color = _tierColor[tier] ?? AppTheme.textSecondary;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(tier,
          style: TextStyle(
              color: color, fontSize: 10, fontWeight: FontWeight.w800)),
    );
  }

  /// Tiny Aura-cost histogram of the current picks — deck-building at a glance.
  Widget _auraCurve(DeckEditorData data) {
    final counts = _counts ?? const <String, int>{};
    final byCost = List<int>.filled(11, 0); // Aura ramps 1..10 (cap)
    for (final c in data.chits) {
      final q = counts[c.chitId] ?? 0;
      if (q > 0) byCost[c.auraCost.clamp(0, 10)] += q;
    }
    final maxBar =
        byCost.fold(0, (max, v) => v > max ? v : max).clamp(1, 999);

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('AURA CURVE',
            style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 9,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.2)),
        const SizedBox(height: 8),
        SizedBox(
          height: 44,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var cost = 1; cost <= 10; cost++) ...[
                Expanded(
                  child: Column(mainAxisAlignment: MainAxisAlignment.end, children: [
                    Container(
                      height: 30.0 * byCost[cost] / maxBar + 2,
                      margin: const EdgeInsets.symmetric(horizontal: 3),
                      decoration: BoxDecoration(
                        color: byCost[cost] > 0
                            ? AppTheme.primary
                            : AppTheme.cardBorder,
                        borderRadius: BorderRadius.circular(2),
                      ),
                    ),
                    const SizedBox(height: 3),
                    Text('$cost',
                        style: const TextStyle(
                            color: AppTheme.textSecondary, fontSize: 8)),
                  ]),
                ),
              ],
            ],
          ),
        ),
      ]),
    );
  }

  // ── save bar ────────────────────────────────────────────────────────────────
  Widget _bottomBar(DeckEditorData data) {
    final complete = _total == 20;
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        border: Border(top: BorderSide(color: AppTheme.cardBorder)),
      ),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (_errors.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final e in _errors)
                  Text('• $e',
                      style: const TextStyle(
                          color: AppTheme.danger, fontSize: 12)),
              ],
            ),
          ),
        Row(children: [
          Text('$_total/20',
              style: TextStyle(
                  color: complete ? AppTheme.success : AppTheme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w800)),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              complete
                  ? 'Full lineup — save to lock it in.'
                  : 'Add ${20 - _total} more ${20 - _total == 1 ? 'card' : 'cards'} for a legal deck.',
              style:
                  const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
          ),
          FilledButton.icon(
            onPressed: (_dirty && !_saving) ? () => _save(data) : null,
            icon: _saving
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save_outlined, size: 18),
            label: Text(_saving ? 'Saving…' : 'Save deck'),
          ),
        ]),
      ]),
    );
  }
}
