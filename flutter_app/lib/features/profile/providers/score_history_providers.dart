import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

enum ScoreRange { oneDay, oneWeek, oneMonth, threeMonths, ytd }

class ScoreHistoryPoint {
  final int compositeScore;
  final DateTime recordedAt;

  const ScoreHistoryPoint({
    required this.compositeScore,
    required this.recordedAt,
  });

  factory ScoreHistoryPoint.fromJson(Map<String, dynamic> json) {
    return ScoreHistoryPoint(
      compositeScore: (json['composite_score'] as num?)?.toInt() ?? 0,
      recordedAt: DateTime.parse(json['recorded_at'] as String),
    );
  }
}

DateTime _rangeToDate(ScoreRange range) {
  final now = DateTime.now().toUtc();
  switch (range) {
    case ScoreRange.oneDay:
      return now.subtract(const Duration(days: 1));
    case ScoreRange.oneWeek:
      return now.subtract(const Duration(days: 7));
    case ScoreRange.oneMonth:
      return now.subtract(const Duration(days: 30));
    case ScoreRange.threeMonths:
      return now.subtract(const Duration(days: 90));
    case ScoreRange.ytd:
      return DateTime.utc(now.year, 1, 1);
  }
}

final scoreHistoryProvider = FutureProvider.autoDispose
    .family<List<ScoreHistoryPoint>, (String, ScoreRange)>((ref, args) async {
  final userId = args.$1;
  final range = args.$2;
  final since = _rangeToDate(range);

  final res = await Supabase.instance.client
      .from('score_history')
      .select('composite_score, recorded_at')
      .eq('user_id', userId)
      .gte('recorded_at', since.toIso8601String())
      .order('recorded_at');

  return (res as List)
      .map((r) => ScoreHistoryPoint.fromJson(r as Map<String, dynamic>))
      .toList();
});
