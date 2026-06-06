import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/ubi_models.dart';

// Pool balance and config

final ubiPoolBalanceProvider =
    FutureProvider.autoDispose<UbiPoolBalance>((ref) async {
  final data = await Supabase.instance.client
      .from('ubi_pool_balance_cache')
      .select()
      .single();
  return UbiPoolBalance.fromJson(data);
});

final ubiPoolConfigProvider =
    FutureProvider.autoDispose<UbiPoolConfig>((ref) async {
  final data = await Supabase.instance.client
      .from('ubi_pool_config')
      .select('mode, is_open_for_contributions, is_open_for_requests, max_request_pct_of_pool, max_request_usd_cents')
      .single();
  return UbiPoolConfig.fromJson(data);
});

// Recent public disbursement log (landing page impact strip)

final ubiPublicDisbursementsProvider =
    FutureProvider.autoDispose<List<UbiPublicDisbursement>>((ref) async {
  final data = await Supabase.instance.client
      .from('ubi_public_disbursement_log')
      .select()
      .order('created_at', ascending: false)
      .limit(10);
  return (data as List)
      .map((r) => UbiPublicDisbursement.fromJson(r as Map<String, dynamic>))
      .toList();
});

// Current user's withdrawal requests

final myUbiRequestsProvider =
    FutureProvider.autoDispose<List<UbiWithdrawalRequest>>((ref) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return [];
  final data = await Supabase.instance.client
      .from('ubi_withdrawal_requests')
      .select()
      .eq('requester_user_id', userId)
      .order('created_at', ascending: false);
  return (data as List)
      .map((r) => UbiWithdrawalRequest.fromJson(r as Map<String, dynamic>))
      .toList();
});

// A single request (polled during AI review flow)

final ubiRequestDetailProvider =
    FutureProvider.family.autoDispose<UbiWithdrawalRequest?, String>(
        (ref, requestId) async {
  final data = await Supabase.instance.client
      .from('ubi_withdrawal_requests')
      .select()
      .eq('id', requestId)
      .maybeSingle();
  return data == null ? null : UbiWithdrawalRequest.fromJson(data);
});

// AI evaluation result for a request (pass 1 — documents requested)

final ubiAiEvaluationProvider =
    FutureProvider.family.autoDispose<Map<String, dynamic>?, String>(
        (ref, requestId) async {
  final data = await Supabase.instance.client
      .from('ubi_ai_evaluations')
      .select('evaluation_pass, documents_requested, voter_summary, within_fund_scope')
      .eq('request_id', requestId)
      .order('evaluation_pass', ascending: false)
      .limit(1)
      .maybeSingle();
  return data;
});

// My panel assignments (vote inbox)

final myUbiAssignmentsProvider =
    FutureProvider.autoDispose<List<UbiPanelAssignment>>((ref) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return [];
  final data = await Supabase.instance.client
      .from('ubi_panel_assignments')
      .select()
      .eq('voter_user_id', userId)
      .inFilter('assignment_status', ['pending', 'opened'])
      .order('created_at', ascending: false);
  return (data as List)
      .map((r) => UbiPanelAssignment.fromJson(r as Map<String, dynamic>))
      .toList();
});

// A single assignment detail — includes panel + AI voter summary

final ubiAssignmentDetailProvider =
    FutureProvider.family.autoDispose<Map<String, dynamic>?, String>(
        (ref, assignmentId) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return null;

  final assignment = await Supabase.instance.client
      .from('ubi_panel_assignments')
      .select()
      .eq('id', assignmentId)
      .eq('voter_user_id', userId)
      .maybeSingle();

  if (assignment == null) return null;

  final panelId = assignment['panel_id'] as String;
  final requestId = assignment['request_id'] as String;

  // Panel metadata (excluding vote counts — hidden until closed per hard rule)
  final panel = await Supabase.instance.client
      .from('ubi_voting_panels')
      .select('id, status, panel_size, opens_at, closes_at, extended_until, closed_at, outcome, votes_yes, votes_no, votes_received, vote_round')
      .eq('id', panelId)
      .maybeSingle();

  // Request metadata (amount + category — no narrative, no documents)
  final request = await Supabase.instance.client
      .from('ubi_withdrawal_requests')
      .select('amount_requested_usd_cents, emergency_category, status')
      .eq('id', requestId)
      .maybeSingle();

  // AI voter summary (no PII, no recommendation)
  final evaluation = await Supabase.instance.client
      .from('ubi_ai_evaluations')
      .select('voter_summary')
      .eq('request_id', requestId)
      .order('evaluation_pass', ascending: false)
      .limit(1)
      .maybeSingle();

  return {
    'assignment': assignment,
    'panel': panel,
    'request': request,
    'voter_summary': evaluation?['voter_summary'],
  };
});
