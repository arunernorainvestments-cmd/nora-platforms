import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/campaigns_providers.dart';

class CampaignProposalDetailScreen extends ConsumerWidget {
  final String proposalId;
  const CampaignProposalDetailScreen({super.key, required this.proposalId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final proposal = ref.watch(campaignProposalDetailProvider(proposalId));
    final myVote = ref.watch(myVoteProvider(proposalId));

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: proposal.maybeWhen(
          data: (p) =>
              Text(p.title, overflow: TextOverflow.ellipsis),
          orElse: () => const Text('Proposal'),
        ),
      ),
      body: proposal.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => const Center(
          child: Text('Proposal not found',
              style: TextStyle(color: AppTheme.textSecondary)),
        ),
        data: (p) => _ProposalBody(
          proposal: p,
          myVoteAsync: myVote,
          onVote: (vote) async {
            try {
              await castVote(proposalId, vote);
              ref.invalidate(campaignProposalDetailProvider(proposalId));
              ref.invalidate(myVoteProvider(proposalId));
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Vote cast: $vote'),
                    backgroundColor: AppTheme.success,
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                );
              }
            } catch (e) {
              if (context.mounted) {
                final msg = e.toString().contains('ALREADY_VOTED')
                    ? 'You have already voted on this proposal.'
                    : e.toString().contains('NOT_A_BACKER')
                        ? 'Only backers of this campaign can vote.'
                        : 'Failed to cast vote. Please try again.';
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text(msg),
                    backgroundColor: AppTheme.danger,
                    behavior: SnackBarBehavior.floating,
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10)),
                  ),
                );
              }
            }
          },
        ),
      ),
    );
  }
}

class _ProposalBody extends StatefulWidget {
  final Proposal proposal;
  final AsyncValue<String?> myVoteAsync;
  final Future<void> Function(String vote) onVote;

  const _ProposalBody({
    required this.proposal,
    required this.myVoteAsync,
    required this.onVote,
  });

  @override
  State<_ProposalBody> createState() => _ProposalBodyState();
}

class _ProposalBodyState extends State<_ProposalBody> {
  bool _voting = false;

  Future<void> _vote(String vote) async {
    setState(() => _voting = true);
    await widget.onVote(vote);
    if (mounted) setState(() => _voting = false);
  }

  @override
  Widget build(BuildContext context) {
    final p = widget.proposal;
    final fmt = NumberFormat.currency(symbol: '\$', decimalDigits: 0);
    final dateFmt = DateFormat('MMM d, yyyy h:mm a');
    final currentUserId = Supabase.instance.client.auth.currentUser?.id;

    final total = p.totalRoyaltyPctVoted;
    final approvedFrac = total > 0 ? p.royaltyPctApproved / total : 0.0;
    final rejectedFrac = total > 0 ? p.royaltyPctRejected / total : 0.0;

    final myVote = widget.myVoteAsync.valueOrNull;
    final canVote = currentUserId != null &&
        currentUserId != p.creatorId &&
        p.status == ProposalStatus.open &&
        !p.timeRemaining.isNegative &&
        myVote == null;

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        // Status banner
        _StatusBanner(proposal: p),
        const SizedBox(height: 20),

        // Amount + category
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.cardBorder),
          ),
          child: Row(children: [
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                Text(fmt.format(p.amountRequestedUsdCents / 100),
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 24,
                        fontWeight: FontWeight.w800)),
                const Text('requested from escrow',
                    style: TextStyle(
                        color: AppTheme.textSecondary, fontSize: 12)),
              ]),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: AppTheme.cardBorder,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(p.purposeCategory,
                  style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ),
          ]),
        ),
        const SizedBox(height: 16),

        // Description
        const Text('Description',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(p.description,
            style: const TextStyle(
                color: AppTheme.textSecondary, fontSize: 14, height: 1.6)),
        const SizedBox(height: 16),

        // Recipient
        const Text('Where the funds go',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 8),
        Text(p.recipientDescription,
            style: const TextStyle(
                color: AppTheme.textSecondary, fontSize: 14, height: 1.6)),
        const SizedBox(height: 16),

        // Voting window
        Row(children: [
          const Icon(Icons.schedule_outlined,
              size: 14, color: AppTheme.textSecondary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Voting: ${dateFmt.format(p.votingOpensAt.toLocal())} → '
              '${dateFmt.format(p.votingClosesAt.toLocal())}',
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 12),
            ),
          ),
        ]),
        const SizedBox(height: 24),

        // Vote tally
        const Text('Current Tally',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600)),
        const SizedBox(height: 12),
        _TallyBar(
          approvedFrac: approvedFrac,
          rejectedFrac: rejectedFrac,
          royaltyPctApproved: p.royaltyPctApproved,
          royaltyPctRejected: p.royaltyPctRejected,
          totalVoted: total,
          quorumRequired: p.quorumPctRequired,
        ),
        const SizedBox(height: 24),

        // My existing vote
        if (myVote != null) ...[
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3)),
            ),
            child: Row(children: [
              const Icon(Icons.how_to_vote_outlined,
                  color: AppTheme.primary, size: 18),
              const SizedBox(width: 10),
              Text('You voted: ${myVote.toUpperCase()}',
                  style: const TextStyle(
                      color: AppTheme.primary,
                      fontSize: 14,
                      fontWeight: FontWeight.w700)),
            ]),
          ),
          const SizedBox(height: 16),
        ],

        // Vote buttons
        if (canVote) ...[
          const Text('Cast your vote',
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 12),
          Row(children: [
            Expanded(
              child: _VoteButton(
                label: 'Yes',
                color: AppTheme.success,
                icon: Icons.thumb_up_outlined,
                loading: _voting,
                onTap: () => _vote('yes'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _VoteButton(
                label: 'No',
                color: AppTheme.danger,
                icon: Icons.thumb_down_outlined,
                loading: _voting,
                onTap: () => _vote('no'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: _VoteButton(
                label: 'Abstain',
                color: AppTheme.textSecondary,
                icon: Icons.remove_circle_outline,
                loading: _voting,
                onTap: () => _vote('abstain'),
              ),
            ),
          ]),
          const SizedBox(height: 8),
          const Text(
            'Your vote is weighted by your royalty stake. Once cast, votes cannot be changed.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 11, height: 1.5),
          ),
        ],

        const SizedBox(height: 40),
      ]),
    );
  }
}

class _StatusBanner extends StatelessWidget {
  final Proposal proposal;
  const _StatusBanner({required this.proposal});

  @override
  Widget build(BuildContext context) {
    Color color;
    String label;
    IconData icon;

    switch (proposal.status) {
      case ProposalStatus.open:
        final rem = proposal.timeRemaining;
        final h = rem.inHours;
        final timeStr = h >= 24 ? '${rem.inDays}d' : '${h}h';
        label = 'Voting open — $timeStr remaining';
        color = AppTheme.primary;
        icon = Icons.how_to_vote_outlined;
      case ProposalStatus.approved:
        label = 'Approved — awaiting execution';
        color = AppTheme.success;
        icon = Icons.check_circle_outline;
      case ProposalStatus.executed:
        label = 'Executed — funds released';
        color = AppTheme.success;
        icon = Icons.check_circle;
      case ProposalStatus.rejected:
        label = 'Rejected by backers';
        color = AppTheme.danger;
        icon = Icons.cancel_outlined;
      case ProposalStatus.expired:
        label = 'Expired — quorum not reached';
        color = AppTheme.textSecondary;
        icon = Icons.timer_off_outlined;
      case ProposalStatus.cancelled:
        label = 'Cancelled by creator';
        color = AppTheme.textSecondary;
        icon = Icons.block_outlined;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withValues(alpha: 0.35)),
      ),
      child: Row(children: [
        Icon(icon, color: color, size: 18),
        const SizedBox(width: 10),
        Text(label,
            style: TextStyle(
                color: color, fontSize: 14, fontWeight: FontWeight.w600)),
      ]),
    );
  }
}

class _TallyBar extends StatelessWidget {
  final double approvedFrac;
  final double rejectedFrac;
  final double royaltyPctApproved;
  final double royaltyPctRejected;
  final double totalVoted;
  final double quorumRequired;

  const _TallyBar({
    required this.approvedFrac,
    required this.rejectedFrac,
    required this.royaltyPctApproved,
    required this.royaltyPctRejected,
    required this.totalVoted,
    required this.quorumRequired,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: SizedBox(
            height: 12,
            child: Row(children: [
              Flexible(
                flex: (approvedFrac * 100).round().clamp(0, 100),
                child: Container(color: AppTheme.success),
              ),
              Flexible(
                flex: (rejectedFrac * 100).round().clamp(0, 100),
                child: Container(color: AppTheme.danger),
              ),
              Flexible(
                flex: ((1 - approvedFrac - rejectedFrac).clamp(0.0, 1.0) * 100)
                    .round(),
                child: Container(color: AppTheme.cardBorder),
              ),
            ]),
          ),
        ),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          _TallyRow(
            color: AppTheme.success,
            label: 'Yes',
            pct: royaltyPctApproved,
          ),
          _TallyRow(
            color: AppTheme.danger,
            label: 'No',
            pct: royaltyPctRejected,
          ),
          _TallyRow(
            color: AppTheme.textSecondary,
            label: 'Abstain',
            pct: (totalVoted - royaltyPctApproved - royaltyPctRejected)
                .clamp(0.0, double.infinity),
          ),
        ]),
        const SizedBox(height: 12),
        const Divider(color: AppTheme.cardBorder, height: 1),
        const SizedBox(height: 12),
        Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
          Text('${totalVoted.toStringAsFixed(2)}% of stake voted',
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 12)),
          Text('${quorumRequired.toStringAsFixed(0)}% quorum required',
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 12)),
        ]),
      ]),
    );
  }
}

class _TallyRow extends StatelessWidget {
  final Color color;
  final String label;
  final double pct;
  const _TallyRow({required this.color, required this.label, required this.pct});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Text(pct.toStringAsFixed(2),
              style: TextStyle(
                  color: color, fontSize: 16, fontWeight: FontWeight.w700)),
          Text(label,
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 11)),
        ],
      );
}

class _VoteButton extends StatelessWidget {
  final String label;
  final Color color;
  final IconData icon;
  final bool loading;
  final VoidCallback onTap;

  const _VoteButton({
    required this.label,
    required this.color,
    required this.icon,
    required this.loading,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: loading ? null : onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 14),
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: color.withValues(alpha: 0.4)),
          ),
          child: loading
              ? Center(
                  child: SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: color),
                  ),
                )
              : Column(children: [
                  Icon(icon, color: color, size: 20),
                  const SizedBox(height: 4),
                  Text(label,
                      style: TextStyle(
                          color: color,
                          fontSize: 13,
                          fontWeight: FontWeight.w700)),
                ]),
        ),
      );
}
