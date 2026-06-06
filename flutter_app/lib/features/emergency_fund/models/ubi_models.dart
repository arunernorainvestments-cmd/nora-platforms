class UbiPoolBalance {
  final int simBalanceCents;
  final int liveBalanceCents;
  final DateTime lastSyncedAt;

  const UbiPoolBalance({
    required this.simBalanceCents,
    required this.liveBalanceCents,
    required this.lastSyncedAt,
  });

  factory UbiPoolBalance.fromJson(Map<String, dynamic> json) => UbiPoolBalance(
        simBalanceCents: (json['sim_balance_usd_cents'] as num?)?.toInt() ?? 0,
        liveBalanceCents: (json['balance_usd_cents'] as num?)?.toInt() ?? 0,
        lastSyncedAt: DateTime.parse(json['last_synced_at'] as String),
      );
}

class UbiPoolConfig {
  final String mode;
  final bool isOpenForContributions;
  final bool isOpenForRequests;
  final int maxRequestPct;
  final int maxRequestCents;

  const UbiPoolConfig({
    required this.mode,
    required this.isOpenForContributions,
    required this.isOpenForRequests,
    required this.maxRequestPct,
    required this.maxRequestCents,
  });

  bool get isSimulated => mode == 'simulated';

  factory UbiPoolConfig.fromJson(Map<String, dynamic> json) => UbiPoolConfig(
        mode: json['mode'] as String? ?? 'simulated',
        isOpenForContributions: json['is_open_for_contributions'] as bool? ?? true,
        isOpenForRequests: json['is_open_for_requests'] as bool? ?? true,
        maxRequestPct: (json['max_request_pct_of_pool'] as num?)?.toInt() ?? 10,
        maxRequestCents: (json['max_request_usd_cents'] as num?)?.toInt() ?? 100000,
      );
}

class UbiWithdrawalRequest {
  final String id;
  final int amountRequestedCents;
  final String emergencyCategory;
  final String status;
  final int currentVoteRound;
  final bool revoteEligible;
  final DateTime? submittedAt;
  final DateTime? approvedAt;
  final DateTime? disbursedAt;
  final DateTime? deniedAt;
  final DateTime? cooldownUntil;
  final bool isSimulated;

  const UbiWithdrawalRequest({
    required this.id,
    required this.amountRequestedCents,
    required this.emergencyCategory,
    required this.status,
    required this.currentVoteRound,
    required this.revoteEligible,
    this.submittedAt,
    this.approvedAt,
    this.disbursedAt,
    this.deniedAt,
    this.cooldownUntil,
    required this.isSimulated,
  });

  bool get isActive => const {
    'draft', 'pending_ai_review', 'pending_documents',
    'pending_vote', 'voting', 'approved',
    'revote_requested', 'revote_voting',
  }.contains(status);

  String get statusLabel => switch (status) {
    'draft' => 'Draft',
    'pending_ai_review' => 'Under Review',
    'pending_documents' => 'Documents Needed',
    'pending_vote' => 'Vote Pending',
    'voting' => 'Community Voting',
    'approved' => 'Approved',
    'disbursed' => 'Funds Sent',
    'denied' => 'Not Approved',
    'revote_requested' => 'Revote Requested',
    'revote_voting' => 'Revote in Progress',
    'revote_denied' => 'Permanently Closed',
    'withdrawn' => 'Withdrawn',
    'voided' => 'Voided',
    _ => status,
  };

  factory UbiWithdrawalRequest.fromJson(Map<String, dynamic> json) => UbiWithdrawalRequest(
        id: json['id'] as String,
        amountRequestedCents: (json['amount_requested_usd_cents'] as num?)?.toInt() ?? 0,
        emergencyCategory: json['emergency_category'] as String? ?? 'other',
        status: json['status'] as String? ?? 'draft',
        currentVoteRound: (json['current_vote_round'] as num?)?.toInt() ?? 1,
        revoteEligible: json['revote_eligible'] as bool? ?? true,
        submittedAt: json['submitted_at'] != null
            ? DateTime.parse(json['submitted_at'] as String).toLocal()
            : null,
        approvedAt: json['approved_at'] != null
            ? DateTime.parse(json['approved_at'] as String).toLocal()
            : null,
        disbursedAt: json['disbursed_at'] != null
            ? DateTime.parse(json['disbursed_at'] as String).toLocal()
            : null,
        deniedAt: json['denied_at'] != null
            ? DateTime.parse(json['denied_at'] as String).toLocal()
            : null,
        cooldownUntil: json['cooldown_until'] != null
            ? DateTime.parse(json['cooldown_until'] as String).toLocal()
            : null,
        isSimulated: json['is_simulated'] as bool? ?? true,
      );
}

class UbiPanelAssignment {
  final String id;
  final String panelId;
  final String requestId;
  final String assignmentStatus;
  final DateTime? personalDeadline;
  final DateTime? votedAt;

  const UbiPanelAssignment({
    required this.id,
    required this.panelId,
    required this.requestId,
    required this.assignmentStatus,
    this.personalDeadline,
    this.votedAt,
  });

  bool get canVote => assignmentStatus == 'pending' || assignmentStatus == 'opened';

  factory UbiPanelAssignment.fromJson(Map<String, dynamic> json) => UbiPanelAssignment(
        id: json['id'] as String,
        panelId: json['panel_id'] as String,
        requestId: json['request_id'] as String,
        assignmentStatus: json['assignment_status'] as String? ?? 'pending',
        personalDeadline: json['personal_deadline'] != null
            ? DateTime.parse(json['personal_deadline'] as String).toLocal()
            : null,
        votedAt: json['voted_at'] != null
            ? DateTime.parse(json['voted_at'] as String).toLocal()
            : null,
      );
}

class UbiVotingPanel {
  final String id;
  final String requestId;
  final int voteRound;
  final int panelSize;
  final String status;
  final int? votesYes;
  final int? votesNo;
  final int? votesReceived;
  final String? outcome;
  final DateTime? closesAt;
  final DateTime? extendedUntil;
  final DateTime? closedAt;

  const UbiVotingPanel({
    required this.id,
    required this.requestId,
    required this.voteRound,
    required this.panelSize,
    required this.status,
    this.votesYes,
    this.votesNo,
    this.votesReceived,
    this.outcome,
    this.closesAt,
    this.extendedUntil,
    this.closedAt,
  });

  bool get isClosed => status == 'closed' || status == 'timed_out';
  DateTime? get effectiveDeadline => extendedUntil ?? closesAt;

  factory UbiVotingPanel.fromJson(Map<String, dynamic> json) => UbiVotingPanel(
        id: json['id'] as String,
        requestId: json['request_id'] as String,
        voteRound: (json['vote_round'] as num?)?.toInt() ?? 1,
        panelSize: (json['panel_size'] as num?)?.toInt() ?? 11,
        status: json['status'] as String? ?? 'open',
        votesYes: (json['votes_yes'] as num?)?.toInt(),
        votesNo: (json['votes_no'] as num?)?.toInt(),
        votesReceived: (json['votes_received'] as num?)?.toInt(),
        outcome: json['outcome'] as String?,
        closesAt: json['closes_at'] != null
            ? DateTime.parse(json['closes_at'] as String).toLocal()
            : null,
        extendedUntil: json['extended_until'] != null
            ? DateTime.parse(json['extended_until'] as String).toLocal()
            : null,
        closedAt: json['closed_at'] != null
            ? DateTime.parse(json['closed_at'] as String).toLocal()
            : null,
      );
}

class UbiPublicDisbursement {
  final String id;
  final int amountCents;
  final String emergencyCategory;
  final String monthYear;
  final int votesYes;
  final int votesTotal;

  const UbiPublicDisbursement({
    required this.id,
    required this.amountCents,
    required this.emergencyCategory,
    required this.monthYear,
    required this.votesYes,
    required this.votesTotal,
  });

  factory UbiPublicDisbursement.fromJson(Map<String, dynamic> json) => UbiPublicDisbursement(
        id: json['id'] as String,
        amountCents: (json['amount_usd_cents'] as num?)?.toInt() ?? 0,
        emergencyCategory: json['emergency_category'] as String? ?? 'other',
        monthYear: json['month_year'] as String? ?? '',
        votesYes: (json['votes_yes'] as num?)?.toInt() ?? 0,
        votesTotal: (json['votes_total'] as num?)?.toInt() ?? 0,
      );
}
