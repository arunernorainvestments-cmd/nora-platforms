import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../models/platform_metric.dart';
import '../models/score_snapshot.dart';
import '../providers/score_dashboard_providers.dart';

class ScoreDashboardScreen extends ConsumerStatefulWidget {
  const ScoreDashboardScreen({super.key});

  @override
  ConsumerState<ScoreDashboardScreen> createState() =>
      _ScoreDashboardScreenState();
}

class _ScoreDashboardScreenState extends ConsumerState<ScoreDashboardScreen> {
  String _period = '1W';

  static const _periods = ['1D', '1W', '1M', '3M', 'YTD'];

  DateTime _since() {
    final now = DateTime.now();
    return switch (_period) {
      '1D' => now.subtract(const Duration(days: 1)),
      '1W' => now.subtract(const Duration(days: 7)),
      '1M' => now.subtract(const Duration(days: 30)),
      '3M' => now.subtract(const Duration(days: 90)),
      'YTD' => DateTime(now.year, 1, 1),
      _ => now.subtract(const Duration(days: 7)),
    };
  }

  @override
  Widget build(BuildContext context) {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      return const Scaffold(
        body: Center(
          child: Text('Not logged in',
              style: TextStyle(color: AppTheme.textSecondary)),
        ),
      );
    }

    final historyAsync = ref.watch(
      scoreHistoryProvider(ScoreHistoryParams(userId, _since())),
    );
    final metricsAsync = ref.watch(platformMetricsDetailProvider(userId));

    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/explore');
            }
          },
        ),
        title: const Text('Score Dashboard'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── Composite score + chart card ────────────────────────────
            _ScoreChartCard(
              historyAsync: historyAsync,
              period: _period,
              periods: _periods,
              onPeriodChanged: (p) => setState(() => _period = p),
            ),
            const SizedBox(height: 24),

            // ── Per-platform breakdown ───────────────────────────────────
            const _SectionLabel('Platform Breakdown'),
            const SizedBox(height: 12),
            metricsAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => Text(
                'Failed to load platform data: $e',
                style: const TextStyle(color: AppTheme.danger, fontSize: 13),
              ),
              data: (metrics) {
                if (metrics.isEmpty) {
                  return const _EmptyState(
                    message: 'No connected platforms yet.',
                  );
                }
                return Column(
                  children: metrics
                      .map((m) => Padding(
                            padding: const EdgeInsets.only(bottom: 12),
                            child: _PlatformBreakdownCard(metric: m),
                          ))
                      .toList(),
                );
              },
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Score + Chart Card
// ─────────────────────────────────────────────────────────────────────────────

class _ScoreChartCard extends StatelessWidget {
  final AsyncValue<List<ScoreSnapshot>> historyAsync;
  final String period;
  final List<String> periods;
  final void Function(String) onPeriodChanged;

  const _ScoreChartCard({
    required this.historyAsync,
    required this.period,
    required this.periods,
    required this.onPeriodChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Display Score',
            style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 6),
          historyAsync.when(
            loading: () => const SizedBox(
              height: 50,
              child: Center(
                child: SizedBox(
                  width: 20,
                  height: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
            error: (_, __) => const Text('--',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 36,
                    fontWeight: FontWeight.bold)),
            data: (snapshots) => _ScoreHeader(snapshots: snapshots),
          ),

          const SizedBox(height: 20),

          // Period selector
          Row(
            mainAxisAlignment: MainAxisAlignment.start,
            children: periods.map((p) {
              final isSelected = p == period;
              return GestureDetector(
                onTap: () => onPeriodChanged(p),
                child: Container(
                  margin: const EdgeInsets.only(right: 8),
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? AppTheme.primary.withValues(alpha: 0.2)
                        : Colors.transparent,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: isSelected
                          ? AppTheme.primary
                          : AppTheme.cardBorder,
                    ),
                  ),
                  child: Text(
                    p,
                    style: TextStyle(
                      color: isSelected
                          ? AppTheme.primary
                          : AppTheme.textSecondary,
                      fontSize: 12,
                      fontWeight: isSelected
                          ? FontWeight.bold
                          : FontWeight.normal,
                    ),
                  ),
                ),
              );
            }).toList(),
          ),

          const SizedBox(height: 16),

          // Chart
          historyAsync.when(
            loading: () => const SizedBox(
              height: 160,
              child: Center(child: CircularProgressIndicator()),
            ),
            error: (_, __) => const SizedBox(
              height: 160,
              child: Center(
                child: Text('Failed to load chart',
                    style: TextStyle(
                        color: AppTheme.textSecondary, fontSize: 13)),
              ),
            ),
            data: (snapshots) => _Chart(snapshots: snapshots),
          ),
        ],
      ),
    );
  }
}

class _ScoreHeader extends StatelessWidget {
  final List<ScoreSnapshot> snapshots;
  const _ScoreHeader({required this.snapshots});

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final current = snapshots.isNotEmpty ? snapshots.last.compositeScore : 0;
    final start = snapshots.isNotEmpty ? snapshots.first.compositeScore : 0;
    final delta = current - start;
    final isPositive = delta >= 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          fmt.format(current),
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 38,
            fontWeight: FontWeight.bold,
            letterSpacing: -1,
          ),
        ),
        if (snapshots.length > 1) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(
                isPositive ? Icons.arrow_upward : Icons.arrow_downward,
                size: 14,
                color: isPositive ? AppTheme.success : AppTheme.danger,
              ),
              const SizedBox(width: 3),
              Text(
                '${isPositive ? '+' : ''}${fmt.format(delta)} this period',
                style: TextStyle(
                  color: isPositive ? AppTheme.success : AppTheme.danger,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}

class _Chart extends StatelessWidget {
  final List<ScoreSnapshot> snapshots;
  const _Chart({required this.snapshots});

  @override
  Widget build(BuildContext context) {
    if (snapshots.length < 2) {
      return const SizedBox(
        height: 160,
        child: _EmptyState(message: 'Not enough data yet.\nCheck back soon.'),
      );
    }

    final scores = snapshots.map((s) => s.compositeScore.toDouble()).toList();
    final minY = scores.reduce((a, b) => a < b ? a : b);
    final maxY = scores.reduce((a, b) => a > b ? a : b);
    // Add 10% padding; ensure minY doesn't go negative
    final yPadding = ((maxY - minY) * 0.15).clamp(1, double.infinity);
    final chartMinY = (minY - yPadding).clamp(0.0, double.infinity);
    final chartMaxY = maxY + yPadding;

    final spots = scores
        .asMap()
        .entries
        .map((e) => FlSpot(e.key.toDouble(), e.value))
        .toList();

    final startDate = snapshots.first.recordedAt;
    final endDate = snapshots.last.recordedAt;
    final dateRangeLabel =
        '${_fmtDate(startDate)} – ${_fmtDate(endDate)}';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          height: 160,
          child: LineChart(
            LineChartData(
              gridData: FlGridData(
                show: true,
                drawVerticalLine: false,
                horizontalInterval: (chartMaxY - chartMinY) / 4,
                getDrawingHorizontalLine: (_) =>
                    const FlLine(color: AppTheme.cardBorder, strokeWidth: 0.5),
              ),
              titlesData: const FlTitlesData(
                rightTitles:
                    AxisTitles(sideTitles: SideTitles(showTitles: false)),
                topTitles:
                    AxisTitles(sideTitles: SideTitles(showTitles: false)),
                bottomTitles:
                    AxisTitles(sideTitles: SideTitles(showTitles: false)),
                leftTitles:
                    AxisTitles(sideTitles: SideTitles(showTitles: false)),
              ),
              borderData: FlBorderData(show: false),
              minX: 0,
              maxX: (spots.length - 1).toDouble(),
              minY: chartMinY,
              maxY: chartMaxY,
              lineBarsData: [
                LineChartBarData(
                  spots: spots,
                  isCurved: true,
                  curveSmoothness: 0.3,
                  color: AppTheme.primary,
                  barWidth: 2,
                  dotData: const FlDotData(show: false),
                  belowBarData: BarAreaData(
                    show: true,
                    color: AppTheme.primary.withValues(alpha: 0.08),
                  ),
                ),
              ],
              lineTouchData: LineTouchData(
                touchTooltipData: LineTouchTooltipData(
                  getTooltipColor: (_) => AppTheme.surfaceLight,
                  getTooltipItems: (touchedSpots) => touchedSpots.map((s) {
                    final idx = s.x.toInt().clamp(0, snapshots.length - 1);
                    final snap = snapshots[idx];
                    return LineTooltipItem(
                      NumberFormat.decimalPattern()
                          .format(snap.compositeScore),
                      const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 12,
                          fontWeight: FontWeight.bold),
                      children: [
                        TextSpan(
                          text: '\n${_fmtDate(snap.recordedAt)}',
                          style: const TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 11,
                              fontWeight: FontWeight.normal),
                        ),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          dateRangeLabel,
          style: const TextStyle(
              color: AppTheme.textSecondary, fontSize: 11),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  static String _fmtDate(DateTime dt) {
    return DateFormat('MMM d').format(dt);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Per-platform breakdown card
// ─────────────────────────────────────────────────────────────────────────────

class _PlatformBreakdownCard extends StatelessWidget {
  final PlatformMetric metric;
  const _PlatformBreakdownCard({required this.metric});

  static const _platformLabels = {
    'youtube': 'YouTube',
    'twitch': 'Twitch',
    'x': 'X (Twitter)',
  };

  static const _platformIcons = {
    'youtube': Icons.play_circle_outline,
    'twitch': Icons.sports_esports_outlined,
    'x': Icons.alternate_email,
  };

  static const _platformColors = {
    'youtube': Color(0xFFFF4444),
    'twitch': Color(0xFF9146FF),
    'x': Color(0xFF8B8FA8), // textSecondary — X is monochrome
  };

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.decimalPattern();
    final compactFmt = NumberFormat.compact();
    final label = _platformLabels[metric.platform] ?? metric.platform;
    final icon = _platformIcons[metric.platform] ?? Icons.link;
    final color = _platformColors[metric.platform] ?? AppTheme.textSecondary;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surfaceLight,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Platform header + score
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, color: color, size: 18),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.bold),
                    ),
                    if (metric.platformUsername != null)
                      Text(
                        '@${metric.platformUsername}',
                        style: const TextStyle(
                            color: AppTheme.textSecondary, fontSize: 12),
                      ),
                  ],
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    compactFmt.format(metric.displayScore),
                    style: const TextStyle(
                        color: AppTheme.primary,
                        fontSize: 20,
                        fontWeight: FontWeight.bold),
                  ),
                  const Text(
                    'pts',
                    style: TextStyle(
                        color: AppTheme.textSecondary, fontSize: 11),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          const Divider(color: AppTheme.cardBorder, height: 1),
          const SizedBox(height: 12),

          // Raw metrics breakdown
          _MetricRow(
            icon: Icons.people_outline,
            label: metric.platform == 'youtube' ? 'Subscribers' : 'Followers',
            value: fmt.format(metric.followerCount),
            points: metric.followerCount,
            pointsLabel: '×1 pt',
          ),
          if (metric.isLive) ...[
            const SizedBox(height: 8),
            _MetricRow(
              icon: Icons.live_tv_outlined,
              label: 'Live Viewers',
              value: fmt.format(metric.liveViewerCount),
              points: metric.liveViewerCount * 10,
              pointsLabel: '×10 pts',
              isLive: true,
            ),
          ],

          // X-specific post metrics
          if (metric.platform == 'x') ...[
            if ((metric.recentPostViews ?? 0) > 0) ...[
              const SizedBox(height: 8),
              _MetricRow(
                icon: Icons.bar_chart_outlined,
                label: 'Post Impressions',
                value: fmt.format(metric.recentPostViews!),
                points: (metric.recentPostViews! * 0.1).round(),
                pointsLabel: '×0.1 pts',
              ),
            ],
            if ((metric.recentPostReposts ?? 0) > 0) ...[
              const SizedBox(height: 8),
              _MetricRow(
                icon: Icons.repeat_outlined,
                label: 'Post Reposts',
                value: fmt.format(metric.recentPostReposts!),
                points: metric.recentPostReposts! * 3,
                pointsLabel: '×3 pts',
              ),
            ],
            if ((metric.recentPostLikes ?? 0) > 0) ...[
              const SizedBox(height: 8),
              _MetricRow(
                icon: Icons.favorite_outline,
                label: 'Post Likes',
                value: fmt.format(metric.recentPostLikes!),
                points: metric.recentPostLikes!,
                pointsLabel: '×1 pt',
              ),
            ],
            if ((metric.recentPostViews ?? 0) == 0 &&
                (metric.recentPostReposts ?? 0) == 0 &&
                (metric.recentPostLikes ?? 0) == 0) ...[
              const SizedBox(height: 8),
              const Text(
                'Post metrics will appear after your first sync.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _MetricRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final int points;
  final String pointsLabel;
  final bool isLive;

  const _MetricRow({
    required this.icon,
    required this.label,
    required this.value,
    required this.points,
    required this.pointsLabel,
    this.isLive = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon,
            size: 15,
            color: isLive ? AppTheme.danger : AppTheme.textSecondary),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            label,
            style: const TextStyle(
                color: AppTheme.textSecondary, fontSize: 13),
          ),
        ),
        Text(
          value,
          style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600),
        ),
        const SizedBox(width: 8),
        Text(
          pointsLabel,
          style: const TextStyle(
              color: AppTheme.textSecondary, fontSize: 11),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Shared helpers
// ─────────────────────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
          color: AppTheme.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.bold),
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String message;
  const _EmptyState({required this.message});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
      ),
    );
  }
}
