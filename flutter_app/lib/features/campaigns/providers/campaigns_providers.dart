import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ─────────────────────────────────────────────────────────────────────────────
// MODELS
// ─────────────────────────────────────────────────────────────────────────────

enum CampaignStatus {
  draft,
  pending,
  open,
  funded,
  active,
  failed,
  closed;

  static CampaignStatus fromString(String s) =>
      CampaignStatus.values.firstWhere((e) => e.name == s,
          orElse: () => CampaignStatus.draft);

  bool get isPublic =>
      this == open || this == funded || this == active ||
      this == failed || this == closed;
}

class Campaign {
  final String id;
  final String creatorId;
  final String creatorUsername;
  final String title;
  final String? description;
  final String category;
  final String? coverImageUrl;
  final int fundingGoalUsdCents;
  final int currentFundingUsdCents;
  final double royaltyPctOffered;
  final int? royaltyTermYears;
  final int minInvestmentUsdCents;
  final CampaignStatus status;
  final String mode;
  final DateTime? opensAt;
  final DateTime? closesAt;
  final DateTime? fundedAt;
  final DateTime createdAt;
  final int escrowBalanceCents;

  const Campaign({
    required this.id,
    required this.creatorId,
    required this.creatorUsername,
    required this.title,
    this.description,
    required this.category,
    this.coverImageUrl,
    required this.fundingGoalUsdCents,
    required this.currentFundingUsdCents,
    required this.royaltyPctOffered,
    this.royaltyTermYears,
    required this.minInvestmentUsdCents,
    required this.status,
    required this.mode,
    this.opensAt,
    this.closesAt,
    this.fundedAt,
    required this.createdAt,
    this.escrowBalanceCents = 0,
  });

  double get fundingProgressPct =>
      fundingGoalUsdCents > 0
          ? (currentFundingUsdCents / fundingGoalUsdCents).clamp(0.0, 1.0)
          : 0;

  bool get isSimulated => mode == 'simulated';

  factory Campaign.fromJson(Map<String, dynamic> json) {
    final creator = json['creator'] as Map<String, dynamic>? ?? {};
    return Campaign(
      id: json['id'] as String,
      creatorId: json['creator_id'] as String,
      creatorUsername: creator['username'] as String? ?? 'unknown',
      title: json['title'] as String,
      description: json['description'] as String?,
      category: json['category'] as String,
      coverImageUrl: json['cover_image_url'] as String?,
      fundingGoalUsdCents: json['funding_goal_usd_cents'] as int,
      currentFundingUsdCents: json['current_funding_usd_cents'] as int? ?? 0,
      royaltyPctOffered: (json['royalty_pct_offered'] as num).toDouble(),
      royaltyTermYears: json['royalty_term_years'] as int?,
      minInvestmentUsdCents: json['min_investment_usd_cents'] as int? ?? 1000,
      status: CampaignStatus.fromString(json['status'] as String),
      mode: json['mode'] as String? ?? 'simulated',
      opensAt: json['opens_at'] != null
          ? DateTime.parse(json['opens_at'] as String)
          : null,
      closesAt: json['closes_at'] != null
          ? DateTime.parse(json['closes_at'] as String)
          : null,
      fundedAt: json['funded_at'] != null
          ? DateTime.parse(json['funded_at'] as String)
          : null,
      createdAt: DateTime.parse(json['created_at'] as String),
      escrowBalanceCents: json['escrow_balance_usd_cents'] as int? ?? 0,
    );
  }
}

class SimBalance {
  final int balanceUsdCents;
  final int lifetimeInvestedCents;
  final int lifetimeReturnedCents;

  const SimBalance({
    required this.balanceUsdCents,
    required this.lifetimeInvestedCents,
    required this.lifetimeReturnedCents,
  });

  factory SimBalance.fromJson(Map<String, dynamic> json) => SimBalance(
        balanceUsdCents: json['balance_usd_cents'] as int? ?? 0,
        lifetimeInvestedCents: json['lifetime_invested_cents'] as int? ?? 0,
        lifetimeReturnedCents: json['lifetime_returned_cents'] as int? ?? 0,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// PROVIDERS
// ─────────────────────────────────────────────────────────────────────────────

final _db = Supabase.instance.client;

// Publicly visible campaigns (open, funded, active).
final campaignsListProvider = FutureProvider.autoDispose<List<Campaign>>((ref) async {
  final data = await _db
      .from('campaigns')
      .select('*, creator:creator_id(username)')
      .inFilter('status', ['open', 'funded', 'active'])
      .order('created_at', ascending: false);

  return (data as List).map((j) => Campaign.fromJson(j as Map<String, dynamic>)).toList();
});

// Single campaign detail by id.
final campaignDetailProvider =
    FutureProvider.autoDispose.family<Campaign, String>((ref, id) async {
  final data = await _db
      .from('campaigns')
      .select('*, creator:creator_id(username)')
      .eq('id', id)
      .single();

  return Campaign.fromJson(data);
});

// Campaigns the current user created.
final myCreatedCampaignsProvider =
    FutureProvider.autoDispose<List<Campaign>>((ref) async {
  final userId = _db.auth.currentUser?.id;
  if (userId == null) return [];

  final data = await _db
      .from('campaigns')
      .select('*, creator:creator_id(username)')
      .eq('creator_id', userId)
      .order('created_at', ascending: false);

  return (data as List).map((j) => Campaign.fromJson(j as Map<String, dynamic>)).toList();
});

// Campaigns the current user has backed (via ownership ledger).
final myBackedCampaignsProvider =
    FutureProvider.autoDispose<List<Campaign>>((ref) async {
  final userId = _db.auth.currentUser?.id;
  if (userId == null) return [];

  final data = await _db
      .from('campaign_ownership_ledger')
      .select('campaign_id, campaigns(*, creator:creator_id(username))')
      .eq('to_user_id', userId)
      .eq('event_type', 'purchase');

  final seen = <String>{};
  final campaigns = <Campaign>[];
  for (final row in data as List) {
    final c = row['campaigns'] as Map<String, dynamic>?;
    if (c == null) continue;
    final id = c['id'] as String;
    if (seen.add(id)) campaigns.add(Campaign.fromJson(c));
  }
  return campaigns;
});

// Simulated USD balance for current user.
final simBalanceProvider = FutureProvider.autoDispose<SimBalance?>((ref) async {
  final userId = _db.auth.currentUser?.id;
  if (userId == null) return null;

  final data = await _db
      .from('sim_usd_balances')
      .select()
      .eq('user_id', userId)
      .maybeSingle();

  return data == null ? null : SimBalance.fromJson(data);
});

// KYC status for current user.
final kycStatusProvider = FutureProvider.autoDispose<String?>((ref) async {
  final userId = _db.auth.currentUser?.id;
  if (userId == null) return null;

  final data = await _db
      .from('kyc_verifications')
      .select('status')
      .eq('user_id', userId)
      .maybeSingle();

  return data == null ? null : data['status'] as String?;
});

// ─────────────────────────────────────────────────────────────────────────────
// ACTIONS
// ─────────────────────────────────────────────────────────────────────────────

Future<void> seedSimBalanceAndKyc() async {
  final userId = _db.auth.currentUser?.id;
  if (userId == null) return;
  await _db.rpc('sim_seed_balance', params: {'p_user_id': userId});
  await _db.rpc('kyc_simulate_approve', params: {'p_user_id': userId});
}

Future<String> investSimulated({
  required String campaignId,
  required double royaltyPct,
  required int usdCents,
}) async {
  final result = await _db.rpc('campaign_invest_simulated', params: {
    'p_campaign_id': campaignId,
    'p_royalty_pct': royaltyPct,
    'p_usd_cents': usdCents,
  });
  return result as String;
}

Future<void> submitCampaignForReview(String campaignId) async {
  await _db.rpc('campaign_submit_for_review', params: {'p_campaign_id': campaignId});
}

// ─────────────────────────────────────────────────────────────────────────────
// REVENUE EVENT MODELS + PROVIDERS
// ─────────────────────────────────────────────────────────────────────────────

class RevenueEvent {
  final String id;
  final String campaignId;
  final String source;
  final DateTime periodStart;
  final DateTime periodEnd;
  final int grossRevenueCents;
  final int platformFeeCents;
  final int netRevenueCents;
  final int streamCount;
  final int viewCount;
  final String verificationStatus;
  final bool isSimulated;
  final DateTime createdAt;

  const RevenueEvent({
    required this.id,
    required this.campaignId,
    required this.source,
    required this.periodStart,
    required this.periodEnd,
    required this.grossRevenueCents,
    required this.platformFeeCents,
    required this.netRevenueCents,
    required this.streamCount,
    required this.viewCount,
    required this.verificationStatus,
    required this.isSimulated,
    required this.createdAt,
  });

  factory RevenueEvent.fromJson(Map<String, dynamic> json) => RevenueEvent(
        id: json['id'] as String,
        campaignId: json['campaign_id'] as String,
        source: json['source'] as String,
        periodStart: DateTime.parse(json['period_start'] as String),
        periodEnd: DateTime.parse(json['period_end'] as String),
        grossRevenueCents: json['gross_revenue_usd_cents'] as int? ?? 0,
        platformFeeCents: json['platform_fee_usd_cents'] as int? ?? 0,
        netRevenueCents: json['net_revenue_usd_cents'] as int? ?? 0,
        streamCount: json['stream_count'] as int? ?? 0,
        viewCount: json['view_count'] as int? ?? 0,
        verificationStatus: json['verification_status'] as String,
        isSimulated: json['is_simulated'] as bool? ?? false,
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}

class Distribution {
  final String id;
  final String campaignId;
  final String backerUserId;
  final double royaltyPctAtTime;
  final int grossCents;
  final int platformFeeCents;
  final int netCents;
  final String status;
  final bool isSimulated;
  final DateTime? distributedAt;

  const Distribution({
    required this.id,
    required this.campaignId,
    required this.backerUserId,
    required this.royaltyPctAtTime,
    required this.grossCents,
    required this.platformFeeCents,
    required this.netCents,
    required this.status,
    required this.isSimulated,
    this.distributedAt,
  });

  factory Distribution.fromJson(Map<String, dynamic> json) => Distribution(
        id: json['id'] as String,
        campaignId: json['campaign_id'] as String,
        backerUserId: json['backer_user_id'] as String,
        royaltyPctAtTime:
            (json['royalty_pct_at_time'] as num).toDouble(),
        grossCents: json['gross_usd_cents'] as int,
        platformFeeCents: json['platform_fee_usd_cents'] as int? ?? 0,
        netCents: json['net_usd_cents'] as int,
        status: json['status'] as String,
        isSimulated: json['is_simulated'] as bool? ?? false,
        distributedAt: json['distributed_at'] != null
            ? DateTime.parse(json['distributed_at'] as String)
            : null,
      );
}

// Revenue events for a campaign (creator view — all events).
final campaignRevenueEventsProvider =
    FutureProvider.autoDispose.family<List<RevenueEvent>, String>(
        (ref, campaignId) async {
  final data = await _db
      .from('campaign_revenue_events')
      .select()
      .eq('campaign_id', campaignId)
      .order('period_start', ascending: false);

  return (data as List)
      .map((j) => RevenueEvent.fromJson(j as Map<String, dynamic>))
      .toList();
});

// All distributions for the current user (backer earnings dashboard).
final myDistributionsProvider =
    FutureProvider.autoDispose<List<Distribution>>((ref) async {
  final userId = _db.auth.currentUser?.id;
  if (userId == null) return [];

  final data = await _db
      .from('campaign_distributions')
      .select()
      .eq('backer_user_id', userId)
      .order('created_at', ascending: false);

  return (data as List)
      .map((j) => Distribution.fromJson(j as Map<String, dynamic>))
      .toList();
});

// Distributions for a single campaign + current user (backer view).
final myCampaignDistributionsProvider =
    FutureProvider.autoDispose.family<List<Distribution>, String>(
        (ref, campaignId) async {
  final userId = _db.auth.currentUser?.id;
  if (userId == null) return [];

  final data = await _db
      .from('campaign_distributions')
      .select()
      .eq('campaign_id', campaignId)
      .eq('backer_user_id', userId)
      .order('created_at', ascending: false);

  return (data as List)
      .map((j) => Distribution.fromJson(j as Map<String, dynamic>))
      .toList();
});

// ─────────────────────────────────────────────────────────────────────────────
// GOVERNANCE MODELS
// ─────────────────────────────────────────────────────────────────────────────

enum ProposalStatus {
  open,
  approved,
  rejected,
  cancelled,
  executed,
  expired;

  static ProposalStatus fromString(String s) =>
      ProposalStatus.values.firstWhere((e) => e.name == s,
          orElse: () => ProposalStatus.expired);

  bool get isActive => this == open;
  bool get isSettled =>
      this == approved || this == rejected || this == executed || this == expired;
}

class Proposal {
  final String id;
  final String campaignId;
  final String creatorId;
  final String title;
  final String description;
  final int amountRequestedUsdCents;
  final String purposeCategory;
  final String recipientDescription;
  final ProposalStatus status;
  final DateTime votingOpensAt;
  final DateTime votingClosesAt;
  final double totalRoyaltyPctVoted;
  final double royaltyPctApproved;
  final double royaltyPctRejected;
  final double quorumPctRequired;
  final bool isSimulated;
  final DateTime? executedAt;
  final DateTime createdAt;

  const Proposal({
    required this.id,
    required this.campaignId,
    required this.creatorId,
    required this.title,
    required this.description,
    required this.amountRequestedUsdCents,
    required this.purposeCategory,
    required this.recipientDescription,
    required this.status,
    required this.votingOpensAt,
    required this.votingClosesAt,
    required this.totalRoyaltyPctVoted,
    required this.royaltyPctApproved,
    required this.royaltyPctRejected,
    required this.quorumPctRequired,
    required this.isSimulated,
    this.executedAt,
    required this.createdAt,
  });

  Duration get timeRemaining => votingClosesAt.difference(DateTime.now());

  factory Proposal.fromJson(Map<String, dynamic> json) => Proposal(
        id: json['id'] as String,
        campaignId: json['campaign_id'] as String,
        creatorId: json['creator_id'] as String,
        title: json['title'] as String,
        description: json['description'] as String,
        amountRequestedUsdCents: json['amount_requested_usd_cents'] as int,
        purposeCategory: json['purpose_category'] as String,
        recipientDescription: json['recipient_description'] as String,
        status: ProposalStatus.fromString(json['status'] as String),
        votingOpensAt: DateTime.parse(json['voting_opens_at'] as String),
        votingClosesAt: DateTime.parse(json['voting_closes_at'] as String),
        totalRoyaltyPctVoted:
            (json['total_royalty_pct_voted'] as num).toDouble(),
        royaltyPctApproved: (json['royalty_pct_approved'] as num).toDouble(),
        royaltyPctRejected: (json['royalty_pct_rejected'] as num).toDouble(),
        quorumPctRequired: (json['quorum_pct_required'] as num).toDouble(),
        isSimulated: json['is_simulated'] as bool? ?? false,
        executedAt: json['executed_at'] != null
            ? DateTime.parse(json['executed_at'] as String)
            : null,
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}

class CampaignUpdate {
  final String id;
  final String campaignId;
  final String creatorId;
  final String title;
  final String body;
  final String updateType;
  final String? linkedProposalId;
  final String? linkedRevenueEventId;
  final bool isSimulated;
  final DateTime? publishedAt;
  final DateTime createdAt;

  const CampaignUpdate({
    required this.id,
    required this.campaignId,
    required this.creatorId,
    required this.title,
    required this.body,
    required this.updateType,
    this.linkedProposalId,
    this.linkedRevenueEventId,
    required this.isSimulated,
    this.publishedAt,
    required this.createdAt,
  });

  factory CampaignUpdate.fromJson(Map<String, dynamic> json) => CampaignUpdate(
        id: json['id'] as String,
        campaignId: json['campaign_id'] as String,
        creatorId: json['creator_id'] as String,
        title: json['title'] as String,
        body: json['body'] as String,
        updateType: json['update_type'] as String,
        linkedProposalId: json['linked_proposal_id'] as String?,
        linkedRevenueEventId: json['linked_revenue_event_id'] as String?,
        isSimulated: json['is_simulated'] as bool? ?? false,
        publishedAt: json['published_at'] != null
            ? DateTime.parse(json['published_at'] as String)
            : null,
        createdAt: DateTime.parse(json['created_at'] as String),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// GOVERNANCE PROVIDERS
// ─────────────────────────────────────────────────────────────────────────────

// All proposals for a campaign, newest first.
final campaignProposalsProvider =
    FutureProvider.autoDispose.family<List<Proposal>, String>(
        (ref, campaignId) async {
  final data = await _db
      .from('campaign_proposals')
      .select()
      .eq('campaign_id', campaignId)
      .order('created_at', ascending: false);

  return (data as List)
      .map((j) => Proposal.fromJson(j as Map<String, dynamic>))
      .toList();
});

// Single proposal by ID.
final campaignProposalDetailProvider =
    FutureProvider.autoDispose.family<Proposal, String>((ref, id) async {
  final data = await _db
      .from('campaign_proposals')
      .select()
      .eq('id', id)
      .single();
  return Proposal.fromJson(data);
});

// Current user's vote on a specific proposal (null = not voted).
final myVoteProvider =
    FutureProvider.autoDispose.family<String?, String>((ref, proposalId) async {
  final userId = _db.auth.currentUser?.id;
  if (userId == null) return null;

  final data = await _db
      .from('campaign_votes')
      .select('vote')
      .eq('proposal_id', proposalId)
      .eq('voter_user_id', userId)
      .maybeSingle();

  return data == null ? null : data['vote'] as String?;
});

// Published updates for a campaign, newest first.
final campaignUpdatesProvider =
    FutureProvider.autoDispose.family<List<CampaignUpdate>, String>(
        (ref, campaignId) async {
  final data = await _db
      .from('campaign_updates')
      .select()
      .eq('campaign_id', campaignId)
      .not('published_at', 'is', null)
      .order('published_at', ascending: false);

  return (data as List)
      .map((j) => CampaignUpdate.fromJson(j as Map<String, dynamic>))
      .toList();
});

// ─────────────────────────────────────────────────────────────────────────────
// GOVERNANCE ACTIONS
// ─────────────────────────────────────────────────────────────────────────────

Future<String> createProposal({
  required String campaignId,
  required String title,
  required String description,
  required int amountRequestedUsdCents,
  required String purposeCategory,
  required String recipientDescription,
}) async {
  final result = await _db.rpc('campaign_create_proposal', params: {
    'p_campaign_id': campaignId,
    'p_title': title,
    'p_description': description,
    'p_amount_requested_usd_cents': amountRequestedUsdCents,
    'p_purpose_category': purposeCategory,
    'p_recipient_description': recipientDescription,
  });
  // Notify backers (best-effort, ignore errors)
  try {
    await _db.rpc('campaign_notify_proposal', params: {'p_proposal_id': result});
  } catch (_) {}
  return result as String;
}

Future<void> castVote(String proposalId, String vote) async {
  await _db.rpc('campaign_cast_vote', params: {
    'p_proposal_id': proposalId,
    'p_vote': vote,
  });
}

Future<String> postCampaignUpdate({
  required String campaignId,
  required String title,
  required String body,
  required String updateType,
  String? linkedProposalId,
  String? linkedRevenueEventId,
}) async {
  final result = await _db.rpc('campaign_post_update', params: {
    'p_campaign_id': campaignId,
    'p_title': title,
    'p_body': body,
    'p_update_type': updateType,
    'p_linked_proposal_id': linkedProposalId,
    'p_linked_revenue_event_id': linkedRevenueEventId,
  });
  return result as String;
}

Future<String> submitRevenueEvent({
  required String campaignId,
  required String source,
  required DateTime periodStart,
  required DateTime periodEnd,
  required int grossCents,
  required int platformFeeCents,
  required int netCents,
  int streamCount = 0,
  int viewCount = 0,
  String? evidenceUrl,
}) async {
  final result = await _db.rpc('campaign_submit_revenue_event', params: {
    'p_campaign_id': campaignId,
    'p_source': source,
    'p_period_start': periodStart.toIso8601String().substring(0, 10),
    'p_period_end': periodEnd.toIso8601String().substring(0, 10),
    'p_gross_revenue_usd_cents': grossCents,
    'p_platform_fee_usd_cents': platformFeeCents,
    'p_net_revenue_usd_cents': netCents,
    'p_stream_count': streamCount,
    'p_view_count': viewCount,
    'p_evidence_url': evidenceUrl,
  });
  return result as String;
}
