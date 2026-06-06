import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/poll_models.dart';

// Current open poll (null if none)
final currentOpenPollProvider =
    FutureProvider.autoDispose<WeeklyPoll?>((ref) async {
  final data = await Supabase.instance.client
      .from('weekly_polls')
      .select()
      .eq('status', 'open')
      .order('closes_at', ascending: false)
      .limit(1)
      .maybeSingle();
  return data == null ? null : WeeklyPoll.fromJson(data);
});

// Poll options as a stream (live vote updates)
final pollOptionsStreamProvider =
    StreamProvider.family.autoDispose<List<PollOption>, String>((ref, pollId) {
  return Supabase.instance.client
      .from('poll_options')
      .stream(primaryKey: ['id'])
      .eq('poll_id', pollId)
      .map((rows) {
        final opts =
            rows.map((r) => PollOption.fromJson(r)).toList();
        opts.sort((a, b) => b.weightedVoteTotal.compareTo(a.weightedVoteTotal));
        return opts;
      });
});

// Top 5 poll leaders for the current open poll (home screen strip)
final pollLeadersProvider =
    FutureProvider.autoDispose<List<PollOption>>((ref) async {
  final poll = await ref.watch(currentOpenPollProvider.future);
  if (poll == null) return [];

  final data = await Supabase.instance.client
      .from('poll_options')
      .select()
      .eq('poll_id', poll.id)
      .order('weighted_vote_total', ascending: false)
      .limit(5);
  return (data as List)
      .map((r) => PollOption.fromJson(r as Map<String, dynamic>))
      .toList();
});

// Has the current user voted in a given poll?
final hasVotedProvider =
    FutureProvider.family.autoDispose<bool, String>((ref, pollId) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return false;
  final data = await Supabase.instance.client
      .from('poll_votes')
      .select('id')
      .eq('poll_id', pollId)
      .eq('voter_user_id', userId)
      .maybeSingle();
  return data != null;
});
