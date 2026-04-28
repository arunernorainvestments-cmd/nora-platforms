import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../models/arena_match.dart';
import '../models/arena_state_model.dart';
import '../providers/arena_providers.dart';
import '../widgets/orb_widget.dart';
import '../widgets/center_beam_widget.dart';
import '../widgets/power_up_slot_widget.dart';
import '../widgets/event_ticker_widget.dart';
import '../widgets/arena_action_buttons.dart';

class ArenaMatchScreen extends ConsumerStatefulWidget {
  final String matchId;
  const ArenaMatchScreen({super.key, required this.matchId});

  @override
  ConsumerState<ArenaMatchScreen> createState() => _ArenaMatchScreenState();
}

class _ArenaMatchScreenState extends ConsumerState<ArenaMatchScreen>
    with WidgetsBindingObserver {
  Timer? _countdownTimer;
  int _secondsUntilStart = 0;
  bool _appInForeground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _countdownTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Pause animations when app is backgrounded (CLAUDE.md: pause when tabbed out)
    setState(() {
      _appInForeground = state == AppLifecycleState.resumed;
    });
  }

  void _startCountdown(Duration timeUntil) {
    _countdownTimer?.cancel();
    _secondsUntilStart = timeUntil.inSeconds.clamp(0, 999);
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (_secondsUntilStart > 0) _secondsUntilStart--;
      });
    });
  }

  Future<void> _handleBack(String targetId, int amount) async {
    if (!mounted) return;
    try {
      await Supabase.instance.client.rpc('arena_back', params: {
        'p_match_id': widget.matchId,
        'p_target_id': targetId,
        'p_amount': amount,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Backed with $amount tokens'),
            backgroundColor: AppTheme.success,
            duration: const Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString().replaceFirst('Exception: ', '')),
            backgroundColor: AppTheme.danger,
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final matchAsync = ref.watch(arenaMatchProvider(widget.matchId));

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFF0A0A0F), Color(0xFF1A1A2E)],
          ),
        ),
        child: SafeArea(
          child: matchAsync.when(
            loading: () => const Center(
              child: CircularProgressIndicator(color: AppTheme.primary),
            ),
            error: (e, _) => _ErrorView(error: e.toString()),
            data: (match) => _MatchBody(
              match: match,
              matchId: widget.matchId,
              appInForeground: _appInForeground,
              onStartCountdown: _startCountdown,
              secondsUntilStart: _secondsUntilStart,
              onBack: _handleBack,
            ),
          ),
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _MatchBody extends ConsumerStatefulWidget {
  final ArenaMatch match;
  final String matchId;
  final bool appInForeground;
  final void Function(Duration) onStartCountdown;
  final int secondsUntilStart;
  final void Function(String, int) onBack;

  const _MatchBody({
    required this.match,
    required this.matchId,
    required this.appInForeground,
    required this.onStartCountdown,
    required this.secondsUntilStart,
    required this.onBack,
  });

  @override
  ConsumerState<_MatchBody> createState() => _MatchBodyState();
}

class _MatchBodyState extends ConsumerState<_MatchBody> {
  bool _countdownStarted = false;

  @override
  Widget build(BuildContext context) {
    final stateAsync  = ref.watch(arenaStateProvider(widget.matchId));
    final eventsAsync = ref.watch(arenaEventsProvider(widget.matchId));
    final match       = widget.match;

    final arenaState = stateAsync.valueOrNull
        ?? ArenaStateModel.empty(widget.matchId);
    final events = eventsAsync.valueOrNull ?? [];

    // Start countdown for pre_match state
    if (match.isPreMatch && !_countdownStarted) {
      _countdownStarted = true;
      SchedulerBinding.instance.addPostFrameCallback((_) {
        widget.onStartCountdown(match.timeUntilStart);
      });
    }

    return Column(
      children: [
        // ── Header ──────────────────────────────────────────────────────────
        _MatchHeader(
          match: match,
          arenaState: arenaState,
          secondsUntilStart: widget.secondsUntilStart,
        ),

        const SizedBox(height: 8),

        // ── Pre-match overlay ────────────────────────────────────────────────
        if (match.isPreMatch)
          _PreMatchBanner(secondsUntilStart: widget.secondsUntilStart),

        // ── Resolved overlay ─────────────────────────────────────────────────
        if (match.isResolved)
          _ResolvedBanner(match: match),

        // ── Match arena ──────────────────────────────────────────────────────
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: _ArenaArea(
              match: match,
              state: arenaState,
              events: events,
              appInForeground: widget.appInForeground,
            ),
          ),
        ),

        const SizedBox(height: 8),

        // ── Power-up slots ────────────────────────────────────────────────────
        const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              PowerUpSlotWidget(),
              PowerUpSlotWidget(),
              PowerUpSlotWidget(),
              PowerUpSlotWidget(),
            ],
          ),
        ),

        const SizedBox(height: 8),

        // ── Event ticker ──────────────────────────────────────────────────────
        SizedBox(
          height: 80,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: EventTickerWidget(events: events, match: match),
          ),
        ),

        const SizedBox(height: 8),

        // ── Action buttons ────────────────────────────────────────────────────
        if (match.isLive)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: ArenaActionButtons(
              match: match,
              onBack: widget.onBack,
            ),
          )
        else
          const SizedBox(height: 16),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _MatchHeader extends StatelessWidget {
  final ArenaMatch match;
  final ArenaStateModel arenaState;
  final int secondsUntilStart;

  const _MatchHeader({
    required this.match,
    required this.arenaState,
    required this.secondsUntilStart,
  });

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60).toString().padLeft(2, '0');
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final timeRemaining = match.timeRemaining;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        border: Border(
          bottom: BorderSide(color: AppTheme.cardBorder),
        ),
      ),
      child: Row(
        children: [
          // Back button
          GestureDetector(
            onTap: () {
              if (Navigator.of(context).canPop()) {
                Navigator.of(context).pop();
              }
            },
            child: const Icon(Icons.arrow_back_ios_new,
                color: AppTheme.textSecondary, size: 18),
          ),
          const SizedBox(width: 12),

          // Round badge
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            decoration: BoxDecoration(
              color: AppTheme.secondary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                  color: AppTheme.secondary.withValues(alpha: 0.3)),
            ),
            child: Text(
              'Round ${match.round} · Discovery',
              style: const TextStyle(
                color: AppTheme.secondary,
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 0.4,
              ),
            ),
          ),

          const Spacer(),

          // Timer / state label
          if (match.isPreMatch)
            Text(
              'Starting in ${secondsUntilStart}s',
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 12),
            )
          else if (match.isLive)
            Row(
              children: [
                Container(
                  width: 7,
                  height: 7,
                  decoration: const BoxDecoration(
                    color: AppTheme.danger,
                    shape: BoxShape.circle,
                  ),
                ),
                const SizedBox(width: 5),
                Text(
                  _formatDuration(timeRemaining),
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ],
            )
          else if (match.isResolved)
            const Text(
              'Finished',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),

          const SizedBox(width: 12),

          // Pool total
          Text(
            '${arenaState.totalPool.toInt()} T',
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _ArenaArea extends StatelessWidget {
  final ArenaMatch match;
  final ArenaStateModel state;
  final List<dynamic> events;
  final bool appInForeground;

  const _ArenaArea({
    required this.match,
    required this.state,
    required this.events,
    required this.appInForeground,
  });

  @override
  Widget build(BuildContext context) {
    final totalFlow = state.flowRateP1 + state.flowRateP2;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        // ── P1 side ───────────────────────────────────────────────────────────
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              // Score %
              TweenAnimationBuilder<double>(
                tween: Tween(end: state.fractionP1 * 100),
                duration: const Duration(milliseconds: 3000),
                curve: Curves.easeInOut,
                builder: (ctx, val, _) => Text(
                  '${val.round()}%',
                  style: const TextStyle(
                    color: AppTheme.primary,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // Orb
              OrbWidget(
                flowRate: state.flowRateP1,
                totalFlow: totalFlow,
                color: AppTheme.primary,
                paused: !appInForeground,
              ),
              const SizedBox(height: 10),
              // Player name
              Text(
                match.player1Username,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                'MM · ${match.player1Archetype}',
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),

        // ── Center beam ───────────────────────────────────────────────────────
        CenterBeamWidget(
          state: state,
          colorP1: AppTheme.primary,
          colorP2: AppTheme.secondary,
        ),

        // ── P2 side ───────────────────────────────────────────────────────────
        Expanded(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              TweenAnimationBuilder<double>(
                tween: Tween(end: state.fractionP2 * 100),
                duration: const Duration(milliseconds: 3000),
                curve: Curves.easeInOut,
                builder: (ctx, val, _) => Text(
                  '${val.round()}%',
                  style: const TextStyle(
                    color: AppTheme.secondary,
                    fontSize: 28,
                    fontWeight: FontWeight.w800,
                    fontFeatures: [FontFeature.tabularFigures()],
                  ),
                ),
              ),
              const SizedBox(height: 12),
              OrbWidget(
                flowRate: state.flowRateP2,
                totalFlow: totalFlow,
                color: AppTheme.secondary,
                paused: !appInForeground,
              ),
              const SizedBox(height: 10),
              Text(
                match.player2Username,
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
              Text(
                'MM · ${match.player2Archetype}',
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _PreMatchBanner extends StatelessWidget {
  final int secondsUntilStart;
  const _PreMatchBanner({required this.secondsUntilStart});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.timer_outlined, color: AppTheme.primary, size: 14),
          const SizedBox(width: 6),
          Text(
            'Match starts in ${secondsUntilStart}s — get ready!',
            style: const TextStyle(
              color: AppTheme.primary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _ResolvedBanner extends StatelessWidget {
  final ArenaMatch match;
  const _ResolvedBanner({required this.match});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.success.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.success.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.emoji_events, color: AppTheme.success, size: 14),
          const SizedBox(width: 6),
          Text(
            match.winnerId == match.player1Id
                ? '${match.player1Username} wins!'
                : '${match.player2Username} wins!',
            style: const TextStyle(
              color: AppTheme.success,
              fontSize: 12,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  final String error;
  const _ErrorView({required this.error});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.error_outline, color: AppTheme.danger, size: 40),
            const SizedBox(height: 12),
            Text(
              error,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 16),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Go back'),
            ),
          ],
        ),
      ),
    );
  }
}
