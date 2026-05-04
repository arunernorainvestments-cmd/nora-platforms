import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/celeb.dart';

// ─────────────────────────────────────────────────────────────────────────────
// WEEK HELPERS
// ─────────────────────────────────────────────────────────────────────────────

typedef WeekInfo = ({
  String weekId,
  DateTime start,
  DateTime end,
  bool isResolved,
  String currentWindow,
});

WeekInfo computeCurrentWeek() {
  final now = DateTime.now().toUtc();
  // ISO week: Monday=1 ... Sunday=7
  final dayOfWeek = now.weekday;
  final monday = now.subtract(Duration(days: dayOfWeek - 1));
  final weekStart = DateTime.utc(monday.year, monday.month, monday.day);
  final weekEnd = weekStart.add(const Duration(days: 6, hours: 23, minutes: 59, seconds: 59));

  // ISO week number via Thursday anchor (ISO 8601)
  final thursday = weekStart.add(const Duration(days: 3));
  final jan4 = DateTime.utc(thursday.year, 1, 4);
  final startOfWeek1 = jan4.subtract(Duration(days: jan4.weekday - 1));
  final weekNum = ((weekStart.difference(startOfWeek1).inDays) / 7).floor() + 1;
  final weekId = '${thursday.year}-${weekNum.toString().padLeft(2, '0')}';

  // isResolved: Friday 8 PM ET = Saturday 00:00 UTC → show resolved state Sat/Sun
  final isResolved = now.weekday == DateTime.saturday || now.weekday == DateTime.sunday;

  // Current scoring window: YYYY-MM-DD-AM or YYYY-MM-DD-PM
  final dateStr = now.toIso8601String().substring(0, 10);
  final currentWindow = now.hour < 12 ? '$dateStr-AM' : '$dateStr-PM';

  return (
    weekId: weekId,
    start: weekStart,
    end: weekEnd,
    isResolved: isResolved,
    currentWindow: currentWindow,
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// PROVIDERS — plain Riverpod, no codegen
// ─────────────────────────────────────────────────────────────────────────────

final currentWeekProvider = Provider<WeekInfo>((ref) => computeCurrentWeek());

final hotTopicLeaderboardProvider =
    FutureProvider.autoDispose<List<CelebWeeklyScore>>((ref) async {
  final weekId = ref.watch(currentWeekProvider).weekId;

  final data = await Supabase.instance.client
      .from('celeb_weekly_scores')
      .select('id, week_id, celeb_id, points, rank, story_volume, last_delta, last_tier, reason_text, updated_at, celebs(name, category, image_url)')
      .eq('week_id', weekId)
      .order('rank', ascending: true)
      .order('points', ascending: false);

  return (data as List)
      .map((e) => CelebWeeklyScore.fromJson(e as Map<String, dynamic>))
      .toList();
});

final currentUserWeeklyBetProvider =
    FutureProvider.autoDispose<WeeklyBet?>((ref) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return null;

  final weekId = ref.watch(currentWeekProvider).weekId;

  final data = await Supabase.instance.client
      .from('weekly_bets')
      .select('*')
      .eq('user_id', userId)
      .eq('week_id', weekId)
      .eq('bet_category', 'weekly')
      .maybeSingle();

  if (data == null) return null;
  return WeeklyBet.fromJson(data);
});

// Count of pending simple bets per celeb for current scoring window (social proof)
final simpleBetCountsProvider =
    FutureProvider.autoDispose<Map<String, int>>((ref) async {
  final window = ref.watch(currentWeekProvider).currentWindow;

  final data = await Supabase.instance.client
      .from('weekly_bets')
      .select('celeb_id')
      .eq('bet_category', 'simple')
      .eq('scoring_window', window)
      .eq('status', 'pending');

  final counts = <String, int>{};
  for (final row in data as List) {
    final id = row['celeb_id'] as String?;
    if (id != null) counts[id] = (counts[id] ?? 0) + 1;
  }
  return counts;
});

final hotTopicTokenBalanceProvider =
    FutureProvider.autoDispose<int>((ref) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return 0;
  final res = await Supabase.instance.client
      .from('token_balances')
      .select('available_tokens')
      .eq('user_id', userId)
      .maybeSingle();
  return (res?['available_tokens'] as num?)?.toInt() ?? 0;
});
