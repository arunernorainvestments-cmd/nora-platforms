import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/n_back_button.dart';
import '../providers/matchmaking_providers.dart';

/// Find a Match — the cross-platform CCG queue (NORA_PLATFORMS_CROSSPLAY_SPEC.md).
/// Web and NORA Arena app players share one pool; whoever pairs with you may be
/// on either platform. Flow: pick a deck → search (cancellable, live wait state)
/// → match found → play at /battle/play/:id.
class FindMatchScreen extends ConsumerStatefulWidget {
  const FindMatchScreen({super.key});

  @override
  ConsumerState<FindMatchScreen> createState() => _FindMatchScreenState();
}

enum _Phase { pickDeck, searching, matched }

class _FindMatchScreenState extends ConsumerState<FindMatchScreen>
    with SingleTickerProviderStateMixin {
  _Phase _phase = _Phase.pickDeck;
  String? _deckId;
  String? _error;
  bool _busy = false;
  int _queueSize = 0;
  int _waitSeconds = 0;
  Timer? _pollTimer;
  Timer? _waitTicker;
  bool _navigated = false;
  late final AnimationController _pulse =
      AnimationController(vsync: this, duration: const Duration(seconds: 2))
        ..repeat();

  @override
  void dispose() {
    _pollTimer?.cancel();
    _waitTicker?.cancel();
    _pulse.dispose();
    // Fire-and-forget: leaving the screen abandons the queue (heartbeat expiry
    // is the server-side backstop if this never lands).
    if (_phase == _Phase.searching) {
      MatchmakingService.leave().catchError((_) => <String, dynamic>{});
    }
    super.dispose();
  }

  Future<void> _join(String deckId) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await MatchmakingService.join(deckId);
      if (!mounted) return;
      switch (res['status']) {
        case 'matched':
        case 'in_match':
          _goPlay(res['match_id'] as String);
        case 'queued':
          setState(() {
            _deckId = deckId;
            _phase = _Phase.searching;
            _queueSize = (res['queue_size'] as num?)?.toInt() ?? 1;
            _waitSeconds = 0;
            _busy = false;
          });
          _startWaiting();
        case 'deck_illegal':
          setState(() {
            _busy = false;
            _error =
                'That deck isn\'t battle-legal anymore (a card may have been '
                'retired or listed for sale). Rebuild it and try again.';
          });
        default:
          setState(() {
            _busy = false;
            _error = 'Unexpected response — try again.';
          });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _friendly(e);
        });
      }
    }
  }

  void _startWaiting() {
    // Realtime is the fast path (own ccg_queue row UPDATE carries the match id;
    // watched in build). Polling every 5s is the fallback AND the heartbeat that
    // keeps the entry alive server-side.
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 5), (_) => _poll());
    _waitTicker?.cancel();
    _waitTicker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted && _phase == _Phase.searching) {
        setState(() => _waitSeconds++);
      }
    });
  }

  Future<void> _poll() async {
    try {
      final res = await MatchmakingService.poll();
      if (!mounted || _phase != _Phase.searching) return;
      switch (res['status']) {
        case 'matched':
        case 'in_match':
          _goPlay(res['match_id'] as String);
        case 'queued':
          setState(() {
            _queueSize = (res['queue_size'] as num?)?.toInt() ?? _queueSize;
            _waitSeconds =
                (res['queued_for_seconds'] as num?)?.toInt() ?? _waitSeconds;
          });
        case 'idle':
          // Row vanished (another tab cancelled, or a sweep). Back to deck pick.
          setState(() {
            _phase = _Phase.pickDeck;
            _error = 'The search was cancelled — join again when ready.';
          });
          _pollTimer?.cancel();
          _waitTicker?.cancel();
      }
    } catch (_) {/* transient poll failures are fine; next tick retries */}
  }

  Future<void> _cancel() async {
    _pollTimer?.cancel();
    _waitTicker?.cancel();
    setState(() => _busy = true);
    try {
      final res = await MatchmakingService.leave();
      if (!mounted) return;
      if (res['status'] == 'matched') {
        // Too late — an opponent already locked the match in. Play it.
        _goPlay(res['match_id'] as String);
        return;
      }
      setState(() {
        _phase = _Phase.pickDeck;
        _busy = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _friendly(e);
        });
      }
    }
  }

  void _goPlay(String matchId) {
    if (_navigated || !mounted) return;
    _navigated = true;
    _pollTimer?.cancel();
    _waitTicker?.cancel();
    setState(() => _phase = _Phase.matched);
    // A short beat so "Match found!" registers before the board loads.
    Future.delayed(const Duration(milliseconds: 900), () {
      if (mounted) context.go('/battle/play/$matchId');
    });
  }

  Future<void> _quickBuild() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final deckId = await quickBuildDeck();
      ref.invalidate(myDecksProvider);
      if (!mounted) return;
      setState(() {
        _deckId = deckId;
        _busy = false;
      });
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Quick Deck built from your strongest 20 cards.'),
          backgroundColor: AppTheme.surface));
    } catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = _friendly(e);
        });
      }
    }
  }

  String _friendly(Object e) {
    final s = e.toString();
    if (s.contains('Not signed in')) return 'Sign in to find a match.';
    final m = RegExp(r'Exception: (.*)$').firstMatch(s);
    return m?.group(1) ?? 'Something went wrong. Try again.';
  }

  @override
  Widget build(BuildContext context) {
    // Realtime fast path: our own queue row updating with matched_match_id.
    ref.listen(myQueueRowProvider, (_, next) {
      final row = next.valueOrNull;
      final matchId = row?['matched_match_id'] as String?;
      if (matchId != null && _phase == _Phase.searching) {
        // Consume the row server-side (poll deletes it) then go play.
        MatchmakingService.poll().catchError((_) => <String, dynamic>{});
        _goPlay(matchId);
      }
    });

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: const NBackButton(fallback: '/battle'),
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Find a Match', style: TextStyle(color: Colors.white)),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 560),
            child: switch (_phase) {
              _Phase.pickDeck => _buildDeckPick(),
              _Phase.searching => _buildSearching(),
              _Phase.matched => _buildMatched(),
            },
          ),
        ),
      ),
    );
  }

  // ── deck pick ───────────────────────────────────────────────────────────────
  Widget _buildDeckPick() {
    final decksAsync = ref.watch(myDecksProvider);
    final copiesAsync = ref.watch(ownedPlayableCopiesProvider);

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            gradient: const LinearGradient(
              colors: [Color(0xFF1A1050), Color(0xFF0D2A24)],
            ),
            border: Border.all(color: AppTheme.primary.withValues(alpha: 0.6)),
          ),
          child: const Row(children: [
            Icon(Icons.public, color: AppTheme.secondary, size: 20),
            SizedBox(width: 10),
            Expanded(
              child: Text(
                'One queue, every platform: your opponent may be playing on the '
                'web or in the NORA Arena app.',
                style: TextStyle(
                    color: AppTheme.textSecondary, fontSize: 12, height: 1.4),
              ),
            ),
          ]),
        ),
        const SizedBox(height: 20),
        const Text('Choose your deck',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        const Text('20 cards, max 2 copies of any BattleChit.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
        const SizedBox(height: 12),
        decksAsync.when(
          loading: () => const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Center(
                child: CircularProgressIndicator(color: AppTheme.primary)),
          ),
          error: (e, _) => Text('Could not load decks: $e',
              style: const TextStyle(color: AppTheme.danger, fontSize: 13)),
          data: (decks) => Column(
            children: [
              for (final d in decks)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: InkWell(
                    onTap: () => setState(() => _deckId = d.id),
                    borderRadius: BorderRadius.circular(12),
                    child: Container(
                      padding: const EdgeInsets.all(14),
                      decoration: BoxDecoration(
                        color: AppTheme.surface,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                            color: _deckId == d.id
                                ? AppTheme.primary
                                : AppTheme.cardBorder,
                            width: _deckId == d.id ? 1.5 : 1),
                      ),
                      child: Row(children: [
                        Icon(
                            _deckId == d.id
                                ? Icons.radio_button_checked
                                : Icons.radio_button_off,
                            size: 18,
                            color: _deckId == d.id
                                ? AppTheme.primary
                                : AppTheme.textSecondary),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(d.name,
                              style: const TextStyle(
                                  color: AppTheme.textPrimary,
                                  fontWeight: FontWeight.w600)),
                        ),
                        Text('${d.cardCount}/20',
                            style: const TextStyle(
                                color: AppTheme.textSecondary, fontSize: 12)),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 3),
                          decoration: BoxDecoration(
                            color: (d.isLegal
                                    ? AppTheme.success
                                    : AppTheme.danger)
                                .withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                          ),
                          child: Text(d.isLegal ? 'LEGAL' : 'NOT LEGAL',
                              style: TextStyle(
                                  color: d.isLegal
                                      ? AppTheme.success
                                      : AppTheme.danger,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800)),
                        ),
                      ]),
                    ),
                  ),
                ),
              if (decks.isEmpty)
                copiesAsync.when(
                  loading: () => const SizedBox.shrink(),
                  error: (_, __) => const SizedBox.shrink(),
                  data: (copies) => Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppTheme.surface,
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: AppTheme.cardBorder),
                    ),
                    child: Column(children: [
                      const Icon(Icons.style_outlined,
                          color: AppTheme.textSecondary, size: 32),
                      const SizedBox(height: 8),
                      Text(
                        copies >= 20
                            ? 'No deck yet — build one from your $copies playable '
                                'cards with one tap.'
                            : 'A battle deck needs 20 cards and you have $copies '
                                'playable ${copies == 1 ? 'copy' : 'copies'}. Mint a '
                                'moment or grab cards on the Chit Market first.',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 13,
                            height: 1.4),
                      ),
                      if (copies < 20) ...[
                        const SizedBox(height: 12),
                        Row(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              OutlinedButton(
                                onPressed: () => context.push('/mint'),
                                child: const Text('Mint a moment'),
                              ),
                              const SizedBox(width: 10),
                              OutlinedButton(
                                onPressed: () => context.push('/market'),
                                child: const Text('Chit Market'),
                              ),
                            ]),
                      ],
                    ]),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        // Quick-build is always offered — a stale deck is one tap from legal.
        OutlinedButton.icon(
          onPressed: _busy ? null : _quickBuild,
          icon: const Icon(Icons.auto_fix_high_outlined, size: 18),
          label: const Text('Quick-build a deck from my best cards'),
        ),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: (_deckId == null || _busy) ? null : () => _join(_deckId!),
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.sports_kabaddi),
          label: const Text('Find a match'),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(_error!,
                style: const TextStyle(color: AppTheme.danger, fontSize: 13)),
          ),
      ],
    );
  }

  // ── searching ───────────────────────────────────────────────────────────────
  Widget _buildSearching() {
    final mm = (_waitSeconds ~/ 60).toString();
    final ss = (_waitSeconds % 60).toString().padLeft(2, '0');
    return Padding(
      padding: const EdgeInsets.all(20),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          AnimatedBuilder(
            animation: _pulse,
            builder: (context, _) => Stack(
              alignment: Alignment.center,
              children: [
                for (final phase in [0.0, 0.5])
                  Opacity(
                    opacity:
                        (1 - ((_pulse.value + phase) % 1.0)).clamp(0.0, 1.0) *
                            0.35,
                    child: Container(
                      width: 90 + 110 * ((_pulse.value + phase) % 1.0),
                      height: 90 + 110 * ((_pulse.value + phase) % 1.0),
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(color: AppTheme.primary, width: 2),
                      ),
                    ),
                  ),
                Container(
                  width: 90,
                  height: 90,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: AppTheme.primary.withValues(alpha: 0.15),
                    border: Border.all(color: AppTheme.primary),
                  ),
                  child: const Icon(Icons.radar,
                      color: AppTheme.primary, size: 40),
                ),
              ],
            ),
          ),
          const SizedBox(height: 28),
          const Text('Searching for an opponent…',
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text('$mm:$ss elapsed · $_queueSize in queue',
              style:
                  const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
          const SizedBox(height: 6),
          const Text('Searching web + NORA Arena app players',
              style:
                  TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
          const SizedBox(height: 32),
          OutlinedButton.icon(
            onPressed: _busy ? null : _cancel,
            icon: const Icon(Icons.close, size: 18),
            label: const Text('Cancel search'),
            style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(_error!,
                  style:
                      const TextStyle(color: AppTheme.danger, fontSize: 13)),
            ),
        ],
      ),
    );
  }

  // ── matched ─────────────────────────────────────────────────────────────────
  Widget _buildMatched() {
    return const Column(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Icon(Icons.flash_on, color: AppTheme.secondary, size: 64),
        SizedBox(height: 16),
        Text('Match found!',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w800)),
        SizedBox(height: 6),
        Text('Loading the board…',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
      ],
    );
  }
}
