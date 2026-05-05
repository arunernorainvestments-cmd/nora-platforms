import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../hot_topic/models/celeb.dart';
import '../../hot_topic/providers/hot_topic_providers.dart';

class CelebrityHeatScreen extends ConsumerStatefulWidget {
  const CelebrityHeatScreen({super.key});

  @override
  ConsumerState<CelebrityHeatScreen> createState() =>
      _CelebrityHeatScreenState();
}

class _CelebrityHeatScreenState
    extends ConsumerState<CelebrityHeatScreen> {
  static final _launchDate = DateTime.utc(2026, 7, 4);

  late Timer _countdownTimer;
  late Duration _remaining;

  final _tickerController = ScrollController();
  Timer? _tickerTimer;

  int? _expandedIndex;

  @override
  void initState() {
    super.initState();
    _remaining = _launchDate.difference(DateTime.now().toUtc());
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _remaining = _launchDate.difference(DateTime.now().toUtc());
        });
      }
    });
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

    final scrollerAsync = ref.watch(newsScrollerProvider);
    final feedAsync = ref.watch(newsfeedProvider);

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
            // TODO: Connect to Supabase Realtime subscription on celeb_score_history
            // When a new row is inserted (scoring run completes), pulse the badge green
            // and trigger a ref.refresh(newsfeedProvider) to reload the feed.
            // Scoring runs twice daily so connection load is minimal.
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
          _TickerStrip(
            controller: _tickerController,
            items: scrollerAsync.valueOrNull ?? [],
          ),
          Expanded(
            child: feedAsync.when(
              loading: () => const Center(
                child: CircularProgressIndicator(
                    color: AppTheme.primary, strokeWidth: 2),
              ),
              error: (e, _) => Center(
                child: Text(
                  'Unable to load stories',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.5),
                      fontSize: 14),
                ),
              ),
              data: (feed) {
                if (feed.isEmpty) {
                  return Center(
                    child: Text(
                      'No stories yet — check back soon',
                      style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.5),
                          fontSize: 14),
                    ),
                  );
                }
                return ListView.builder(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  itemCount: feed.length,
                  itemBuilder: (context, i) {
                    return _EventCard(
                      entry: feed[i],
                      isExpanded: _expandedIndex == i,
                      onTap: () => setState(() {
                        _expandedIndex = _expandedIndex == i ? null : i;
                      }),
                    );
                  },
                );
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
  final List<CelebWeeklyScore> items;

  const _TickerStrip({required this.controller, required this.items});

  @override
  Widget build(BuildContext context) {
    final decoration = BoxDecoration(
      color: AppTheme.surface,
      border: Border(
        bottom: BorderSide(
            color: AppTheme.cardBorder.withValues(alpha: 0.6), width: 1),
      ),
    );

    if (items.isEmpty) {
      return Container(height: 40, decoration: decoration);
    }

    // Duplicate list so the ticker loops smoothly
    final displayItems = [...items, ...items];

    return Container(
      height: 40,
      decoration: decoration,
      child: ListView.separated(
        controller: controller,
        scrollDirection: Axis.horizontal,
        physics: const NeverScrollableScrollPhysics(),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        itemCount: displayItems.length,
        separatorBuilder: (_, __) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Text(
            '·',
            style: TextStyle(
                color: Colors.white.withValues(alpha: 0.25), fontSize: 16),
          ),
        ),
        itemBuilder: (context, i) {
          final item = displayItems[i];
          final isPositive = item.lastDelta > 0;
          final isNegative = item.lastDelta < 0;
          final deltaColor = isPositive
              ? AppTheme.success
              : isNegative
                  ? AppTheme.danger
                  : Colors.white.withValues(alpha: 0.35);
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                item.celebName,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(width: 4),
              Text(
                '${item.points}',
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.5),
                  fontSize: 12,
                ),
              ),
              const SizedBox(width: 3),
              Icon(
                isPositive
                    ? Icons.arrow_drop_up
                    : isNegative
                        ? Icons.arrow_drop_down
                        : Icons.remove,
                color: deltaColor,
                size: 18,
              ),
              Text(
                '${isPositive ? '+' : ''}${item.lastDelta}',
                style: TextStyle(
                  color: deltaColor,
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
  final NewsfeedEntry entry;
  final bool isExpanded;
  final VoidCallback onTap;

  const _EventCard({
    required this.entry,
    required this.isExpanded,
    required this.onTap,
  });

  static Color _avatarColor(String name) {
    const palette = [
      Color(0xFF00BCD4),
      Color(0xFF9C27B0),
      Color(0xFF3F51B5),
      Color(0xFFF44336),
      Color(0xFFFF8F00),
      Color(0xFF8BC34A),
      Color(0xFF009688),
      Color(0xFFE91E63),
      Color(0xFF03A9F4),
      Color(0xFFFF5722),
      Color(0xFF607D8B),
      Color(0xFF795548),
    ];
    int hash = 0;
    for (final ch in name.codeUnits) {
      hash = (hash * 31 + ch) & 0x7FFFFFFF;
    }
    return palette[hash % palette.length];
  }

  static String _tierLabel(String tier) {
    const labels = {
      'Good 4': 'Major moment',
      'Good 3': 'Strong positive',
      'Good 2': 'Positive coverage',
      'Good 1': 'Mild positive',
      'Neutral': 'Neutral',
      'Bad 1': 'Mild criticism',
      'Bad 2': 'Controversy',
      'Bad 3': 'Serious negative',
      'Bad 4': 'Major fallout',
    };
    return labels[tier] ?? tier;
  }

  @override
  Widget build(BuildContext context) {
    final avatarColor = _avatarColor(entry.celebName);
    final deltaColor = entry.isPositive
        ? AppTheme.success
        : entry.isNegative
            ? AppTheme.danger
            : Colors.white.withValues(alpha: 0.35);
    final displayText = entry.reasonText?.isNotEmpty == true
        ? entry.reasonText!
        : 'No significant news this period';

    return GestureDetector(
      onTap: onTap,
      child: Container(
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
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Avatar
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    color: avatarColor.withValues(alpha: 0.25),
                    shape: BoxShape.circle,
                    border: Border.all(
                        color: avatarColor.withValues(alpha: 0.5), width: 1.5),
                  ),
                  child: Center(
                    child: Text(
                      entry.celebInitials,
                      style: TextStyle(
                        color: avatarColor,
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
                            entry.celebName,
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
                                  color: deltaColor.withValues(alpha: 0.35),
                                  width: 1),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  entry.isPositive
                                      ? Icons.arrow_drop_up
                                      : entry.isNegative
                                          ? Icons.arrow_drop_down
                                          : Icons.remove,
                                  color: deltaColor,
                                  size: 16,
                                ),
                                Text(
                                  entry.deltaLabel,
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
                        displayText,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.75),
                          fontSize: 13,
                          height: 1.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        entry.timestampLabel,
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
            // Expandable section — height-only transition, no slide/fade on content
            AnimatedSize(
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeInOut,
              child: isExpanded
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const SizedBox(height: 12),
                        Divider(
                            color: Colors.white.withValues(alpha: 0.1),
                            height: 1),
                        const SizedBox(height: 12),
                        Text(
                          displayText,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.75),
                            fontSize: 13,
                            height: 1.5,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          'Based on ${entry.storyVolume} sources · ${_tierLabel(entry.tier)}',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.4),
                            fontSize: 12,
                          ),
                        ),
                      ],
                    )
                  : const SizedBox.shrink(),
            ),
          ],
        ),
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
