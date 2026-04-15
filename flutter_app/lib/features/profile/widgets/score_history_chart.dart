import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/score_history_providers.dart';

class ScoreHistoryChart extends ConsumerStatefulWidget {
  final String userId;
  const ScoreHistoryChart({super.key, required this.userId});

  @override
  ConsumerState<ScoreHistoryChart> createState() => _ScoreHistoryChartState();
}

class _ScoreHistoryChartState extends ConsumerState<ScoreHistoryChart> {
  ScoreRange _range = ScoreRange.oneWeek;

  static const _tabs = [
    (label: '1D', range: ScoreRange.oneDay),
    (label: '1W', range: ScoreRange.oneWeek),
    (label: '1M', range: ScoreRange.oneMonth),
    (label: '3M', range: ScoreRange.threeMonths),
    (label: 'YTD', range: ScoreRange.ytd),
  ];

  @override
  Widget build(BuildContext context) {
    final historyAsync =
        ref.watch(scoreHistoryProvider((widget.userId, _range)));

    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Range tabs
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 8, 4, 0),
            child: Row(
              children: _tabs.map((t) {
                final selected = _range == t.range;
                return Expanded(
                  child: GestureDetector(
                    onTap: () => setState(() => _range = t.range),
                    child: Container(
                      margin: const EdgeInsets.symmetric(horizontal: 3, vertical: 4),
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      decoration: BoxDecoration(
                        color: selected
                            ? AppTheme.primary.withValues(alpha: 0.18)
                            : Colors.transparent,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: selected ? AppTheme.primary : Colors.transparent,
                        ),
                      ),
                      alignment: Alignment.center,
                      child: Text(
                        t.label,
                        style: TextStyle(
                          color: selected
                              ? AppTheme.primary
                              : AppTheme.textSecondary,
                          fontSize: 12,
                          fontWeight: selected
                              ? FontWeight.w700
                              : FontWeight.normal,
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),

          const SizedBox(height: 8),

          // Chart area
          SizedBox(
            height: 160,
            child: historyAsync.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (_, __) => const Center(
                child: Text(
                  'Could not load score history',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                ),
              ),
              data: (points) {
                if (points.length < 2) {
                  return const Center(
                    child: Text(
                      'No score history yet',
                      style: TextStyle(
                          color: AppTheme.textSecondary, fontSize: 13),
                    ),
                  );
                }

                final spots = points.asMap().entries.map((e) {
                  return FlSpot(
                    e.key.toDouble(),
                    e.value.compositeScore.toDouble(),
                  );
                }).toList();

                final maxY = points
                    .map((p) => p.compositeScore)
                    .reduce((a, b) => a > b ? a : b)
                    .toDouble();
                final minY = points
                    .map((p) => p.compositeScore)
                    .reduce((a, b) => a < b ? a : b)
                    .toDouble();

                // Pad Y range so the line isn't flush against the edges
                final padding = (maxY - minY) * 0.15;
                final chartMinY =
                    (minY - padding).clamp(0.0, double.infinity);
                final chartMaxY = maxY + padding + 1;

                return Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 16, 16),
                  child: LineChart(
                    LineChartData(
                      minY: chartMinY,
                      maxY: chartMaxY,
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: false,
                        horizontalInterval: ((chartMaxY - chartMinY) / 3)
                            .clamp(1.0, double.infinity),
                        getDrawingHorizontalLine: (_) => const FlLine(
                          color: AppTheme.cardBorder,
                          strokeWidth: 1,
                        ),
                      ),
                      borderData: FlBorderData(show: false),
                      titlesData: FlTitlesData(
                        leftTitles: AxisTitles(
                          sideTitles: SideTitles(
                            showTitles: true,
                            reservedSize: 50,
                            getTitlesWidget: (value, meta) {
                              final formatted =
                                  NumberFormat.compact().format(value);
                              return Text(
                                formatted,
                                style: const TextStyle(
                                  color: AppTheme.textSecondary,
                                  fontSize: 10,
                                ),
                              );
                            },
                          ),
                        ),
                        rightTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        topTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                        bottomTitles: const AxisTitles(
                            sideTitles: SideTitles(showTitles: false)),
                      ),
                      lineTouchData: LineTouchData(
                        touchTooltipData: LineTouchTooltipData(
                          getTooltipItems: (spots) {
                            return spots.map((s) {
                              final idx = s.x.toInt();
                              final pt = points[idx];
                              final dateStr = DateFormat('MMM d, HH:mm')
                                  .format(pt.recordedAt.toLocal());
                              return LineTooltipItem(
                                '${NumberFormat('#,###').format(pt.compositeScore)} pts\n$dateStr',
                                const TextStyle(
                                  color: AppTheme.textPrimary,
                                  fontSize: 11,
                                ),
                              );
                            }).toList();
                          },
                        ),
                      ),
                      lineBarsData: [
                        LineChartBarData(
                          spots: spots,
                          isCurved: true,
                          color: AppTheme.secondary,
                          barWidth: 2,
                          dotData: const FlDotData(show: false),
                          belowBarData: BarAreaData(
                            show: true,
                            gradient: LinearGradient(
                              colors: [
                                AppTheme.secondary.withValues(alpha: 0.25),
                                AppTheme.secondary.withValues(alpha: 0.0),
                              ],
                              begin: Alignment.topCenter,
                              end: Alignment.bottomCenter,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}
