import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/campaigns_providers.dart';

class CampaignProposalsScreen extends ConsumerWidget {
  final String campaignId;
  final bool isCreator;
  final int escrowBalanceCents;

  const CampaignProposalsScreen({
    super.key,
    required this.campaignId,
    required this.isCreator,
    required this.escrowBalanceCents,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final proposals = ref.watch(campaignProposalsProvider(campaignId));

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: const Text('Governance Proposals'),
      ),
      floatingActionButton: isCreator
          ? FloatingActionButton.extended(
              backgroundColor: AppTheme.primary,
              onPressed: () => context.push(
                '/campaign/$campaignId/proposals/new',
                extra: escrowBalanceCents,
              ),
              icon: const Icon(Icons.add, color: Colors.white),
              label: const Text('New Proposal',
                  style: TextStyle(color: Colors.white, fontWeight: FontWeight.w700)),
            )
          : null,
      body: proposals.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => const Center(
          child: Text('Failed to load proposals',
              style: TextStyle(color: AppTheme.textSecondary)),
        ),
        data: (list) {
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.how_to_vote_outlined,
                        size: 48, color: AppTheme.textSecondary),
                    const SizedBox(height: 16),
                    const Text('No proposals yet',
                        style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Text(
                      isCreator
                          ? 'Create a proposal to request funds from escrow.'
                          : 'The creator has not submitted any proposals yet.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: AppTheme.textSecondary, height: 1.5),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(20),
            itemCount: list.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, i) => _ProposalCard(
              proposal: list[i],
              onTap: () => context.push(
                '/campaign/$campaignId/proposals/${list[i].id}',
              ),
            ),
          );
        },
      ),
    );
  }
}

class _ProposalCard extends StatelessWidget {
  final Proposal proposal;
  final VoidCallback onTap;
  const _ProposalCard({required this.proposal, required this.onTap});

  Color get _statusColor {
    switch (proposal.status) {
      case ProposalStatus.open:
        return AppTheme.primary;
      case ProposalStatus.approved:
      case ProposalStatus.executed:
        return AppTheme.success;
      case ProposalStatus.rejected:
      case ProposalStatus.expired:
        return AppTheme.danger;
      case ProposalStatus.cancelled:
        return AppTheme.textSecondary;
    }
  }

  String get _statusLabel {
    switch (proposal.status) {
      case ProposalStatus.open:
        final rem = proposal.timeRemaining;
        if (rem.isNegative) return 'Closing';
        final h = rem.inHours;
        if (h >= 24) return '${rem.inDays}d left';
        return '${h}h left';
      case ProposalStatus.approved:
        return 'Approved';
      case ProposalStatus.executed:
        return 'Executed';
      case ProposalStatus.rejected:
        return 'Rejected';
      case ProposalStatus.expired:
        return 'Expired (no quorum)';
      case ProposalStatus.cancelled:
        return 'Cancelled';
    }
  }

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.currency(symbol: '\$', decimalDigits: 0);
    final total = proposal.totalRoyaltyPctVoted;
    final approvedFrac = total > 0 ? proposal.royaltyPctApproved / total : 0.0;
    final rejectedFrac = total > 0 ? proposal.royaltyPctRejected / total : 0.0;

    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: proposal.status == ProposalStatus.open
                ? AppTheme.primary.withValues(alpha: 0.35)
                : AppTheme.cardBorder,
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Expanded(
                child: Text(proposal.title,
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ),
              const SizedBox(width: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: _statusColor.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(20),
                  border: Border.all(color: _statusColor.withValues(alpha: 0.4)),
                ),
                child: Text(_statusLabel,
                    style: TextStyle(
                        color: _statusColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w700)),
              ),
            ]),
            const SizedBox(height: 8),
            Row(children: [
              const Icon(Icons.attach_money,
                  size: 14, color: AppTheme.textSecondary),
              const SizedBox(width: 3),
              Text(fmt.format(proposal.amountRequestedUsdCents / 100),
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 13)),
              const SizedBox(width: 12),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppTheme.cardBorder,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(proposal.purposeCategory,
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 11)),
              ),
            ]),
            if (total > 0) ...[
              const SizedBox(height: 12),
              _VoteTally(
                approvedFrac: approvedFrac,
                rejectedFrac: rejectedFrac,
                totalVoted: total,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _VoteTally extends StatelessWidget {
  final double approvedFrac;
  final double rejectedFrac;
  final double totalVoted;
  const _VoteTally({
    required this.approvedFrac,
    required this.rejectedFrac,
    required this.totalVoted,
  });

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      ClipRRect(
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(
          height: 6,
          child: Row(children: [
            Flexible(
              flex: (approvedFrac * 100).round(),
              child: Container(color: AppTheme.success),
            ),
            Flexible(
              flex: (rejectedFrac * 100).round(),
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
      const SizedBox(height: 5),
      Row(children: [
        _TallyLabel(
            color: AppTheme.success,
            label: 'Yes ${(approvedFrac * 100).toStringAsFixed(1)}%'),
        const SizedBox(width: 12),
        _TallyLabel(
            color: AppTheme.danger,
            label: 'No ${(rejectedFrac * 100).toStringAsFixed(1)}%'),
        const Spacer(),
        Text('${totalVoted.toStringAsFixed(2)}% voted',
            style: const TextStyle(
                color: AppTheme.textSecondary, fontSize: 11)),
      ]),
    ]);
  }
}

class _TallyLabel extends StatelessWidget {
  final Color color;
  final String label;
  const _TallyLabel({required this.color, required this.label});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 8, height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          Text(label,
              style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      );
}
