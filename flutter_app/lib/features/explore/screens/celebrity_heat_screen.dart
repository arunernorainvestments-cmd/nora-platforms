import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../models/celebrity_data.dart';

class CelebrityHeatScreen extends StatefulWidget {
  const CelebrityHeatScreen({super.key});

  @override
  State<CelebrityHeatScreen> createState() => _CelebrityHeatScreenState();
}

class _CelebrityHeatScreenState extends State<CelebrityHeatScreen> {
  static final _launchDate = DateTime.utc(2026, 7, 4);

  late Timer _countdownTimer;
  late Duration _remaining;

  final _tickerController = ScrollController();
  Timer? _tickerTimer;

  late final List<(Celebrity, CelebrityEvent)> _feed;

  @override
  void initState() {
    super.initState();

    // Build flat sorted feed
    _feed = [
      for (final celeb in kCelebrities)
        for (final event in celeb.events) (celeb, event),
    ]..sort((a, b) => a.$2.sortOrder.compareTo(b.$2.sortOrder));

    // Countdown
    _remaining = _launchDate.difference(DateTime.now().toUtc());
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _remaining = _launchDate.difference(DateTime.now().toUtc());
        });
      }
    });

    // Auto-scroll ticker
    WidgetsBinding.instance.addPostFrameCallback((_) => _startTicker());
  }

  void _startTicker() {
    _tickerTimer = Timer.periodic(const Duration(milliseconds: 30), (_) {
      if (!_tickerController.hasClients) return;
      final max = _tickerController.position.maxScrollExtent;
      final current = _tickerController.offset;
      if (current >= max) {
        _tickerController.jumpTo(0);
      } else {
        _tickerController.jumpTo(current + 1.2);
      }
    });
  }

  @override
  void dispose() {
    _countdownTimer.cancel();
    _tickerTimer?.cancel();
    _tickerController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = _remaining.isNegative ? Duration.zero : _remaining;
    final days = r.inDays;
    final hours = r.inHours % 24;
    final minutes = r.inMinutes % 60;
    final seconds = r.inSeconds % 60;

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        elevation: 0,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded,
              color: Colors.white, size: 20),
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/home');
            }
          },
        ),
        title: const Row(
          children: [
            Text(
              '🔥',
              style: TextStyle(fontSize: 18),
            ),
            SizedBox(width: 8),
            Text(
              'Creator Heat',
              style: TextStyle(
                color: Colors.white,
                fontSize: 18,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
        actions: const [
          Padding(
            padding: EdgeInsets.only(right: 16),
            child: Text(
              'LIVE',
              style: TextStyle(
                color: AppTheme.success,
                fontSize: 11,
                fontWeight: FontWeight.w700,
                letterSpacing: 1.5,
              ),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          _TickerStrip(controller: _tickerController),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              itemCount: _feed.length,
              itemBuilder: (context, i) {
                final (celeb, event) = _feed[i];
                return _EventCard(celebrity: celeb, event: event);
              },
            ),
          ),
          _MiniCountdownBanner(
            days: days,
            hours: hours,
            minutes: minutes,
            seconds: seconds,
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// TICKER STRIP
// ─────────────────────────────────────────────────────────────────────────────

class _TickerStrip extends StatelessWidget {
  final ScrollController controller;
  const _TickerStrip({required this.controller});

  @override
  Widget build(BuildContext context) {
    // Duplicate list so the ticker loops smoothly
    final items = [...kCelebrities, ...kCelebrities];

    return Container(
      height: 40,
      decoration: BoxDecoration(
        color: AppTheme.surface,
        border: Border(
          bottom: BorderSide(
              color: AppTheme.cardBorder.withValues(alpha: 0.6), width: 1),
        ),
      ),
      child: ListView.separated(
        controller: controller,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: items.length,
        separatorBuilder: (_, __) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '·',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.25), fontSize: 16),
          ),
        ),
        itemBuilder: (context, i) {
          final celeb = items[i];
          final isPositive = celeb.recentDelta >= 0;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                celeb.name,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                celeb.currentScore.toString(),
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 3),
              Icon(
                isPositive ? Icons.arrow_drop_up : Icons.arrow_drop_down,
                color: isPositive ? AppTheme.success : AppTheme.danger,
                size: 18,
              ),
              Text(
                '${isPositive ? '+' : ''}${celeb.recentDelta}',
                style: TextStyle(
                  color: isPositive ? AppTheme.success : AppTheme.danger,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// EVENT CARD
// ─────────────────────────────────────────────────────────────────────────────

class _EventCard extends StatelessWidget {
  final Celebrity celebrity;
  final CelebrityEvent event;

  const _EventCard({required this.celebrity, required this.event});

  @override
  Widget build(BuildContext context) {
    final isPositive = event.delta >= 0;
    final deltaColor = isPositive ? AppTheme.success : AppTheme.danger;

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: deltaColor.withValues(alpha: 0.2),
          width: 1,
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Avatar
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: celebrity.avatarColor.withValues(alpha: 0.25),
              shape: BoxShape.circle,
              border: Border.all(
                  color: celebrity.avatarColor.withValues(alpha: 0.5), width: 1.5),
            ),
            child: Center(
              child: Text(
                celebrity.initials,
                style: TextStyle(
                  color: celebrity.avatarColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
          const SizedBox(width: 14),
          // Content
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      celebrity.name,
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 14,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    const Spacer(),
                    // Delta badge
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: deltaColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(20),
                        border: Border.all(
                            color: deltaColor.withValues(alpha: 0.35), width: 1),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            isPositive
                                ? Icons.arrow_drop_up
                                : Icons.arrow_drop_down,
                            color: deltaColor,
                            size: 16,
                          ),
                          Text(
                            '${isPositive ? '+' : ''}${event.delta} pts',
                            style: TextStyle(
                              color: deltaColor,
                              fontSize: 12,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                Text(
                  event.headline,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.75),
                    fontSize: 13,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  event.timeAgo,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.35),
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MINI COUNTDOWN BANNER
// ─────────────────────────────────────────────────────────────────────────────

class _MiniCountdownBanner extends StatelessWidget {
  final int days, hours, minutes, seconds;

  const _MiniCountdownBanner({
    required this.days,
    required this.hours,
    required this.minutes,
    required this.seconds,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.go('/'),
      child: Container(
        width: double.infinity,
        padding: EdgeInsets.only(
          top: 12,
          bottom: MediaQuery.of(context).padding.bottom + 12,
          left: 20,
          right: 20,
        ),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          border: Border(
            top: BorderSide(
                color: AppTheme.primary.withValues(alpha: 0.3), width: 1),
          ),
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Text('🚀', style: TextStyle(fontSize: 14)),
            const SizedBox(width: 10),
            _miniUnit(days, 'd'),
            _sep(),
            _miniUnit(hours, 'h'),
            _sep(),
            _miniUnit(minutes, 'm'),
            _sep(),
            _miniUnit(seconds, 's'),
            const SizedBox(width: 14),
            Container(
                width: 1,
                height: 16,
                color: Colors.white.withValues(alpha: 0.2)),
            const SizedBox(width: 14),
            Text(
              'Join the waitlist for launch',
              style: TextStyle(
                color: AppTheme.primary.withValues(alpha: 0.9),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(width: 4),
            Icon(Icons.arrow_forward_ios_rounded,
                color: AppTheme.primary.withValues(alpha: 0.7), size: 11),
          ],
        ),
      ),
    );
  }

  Widget _miniUnit(int value, String label) {
    return RichText(
      text: TextSpan(
        children: [
          TextSpan(
            text: value.toString().padLeft(2, '0'),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
          TextSpan(
            text: label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _sep() => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 3),
        child: Text(
          ':',
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.3),
              fontSize: 13,
              fontWeight: FontWeight.w300),
        ),
      );
}
