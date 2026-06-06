import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../models/ubi_models.dart';
import '../providers/ubi_providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class VoteScreen extends ConsumerStatefulWidget {
  final String assignmentId;

  const VoteScreen({super.key, required this.assignmentId});

  @override
  ConsumerState<VoteScreen> createState() => _VoteScreenState();
}

class _VoteScreenState extends ConsumerState<VoteScreen> {
  bool _isSubmitting = false;
  String? _voteSubmitted;
  Timer? _countdownTimer;
  Duration _remaining = Duration.zero;

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  void _startCountdown(DateTime deadline) {
    _updateRemaining(deadline);
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _updateRemaining(deadline);
    });
  }

  void _updateRemaining(DateTime deadline) {
    final diff = deadline.difference(DateTime.now());
    setState(() => _remaining = diff.isNegative ? Duration.zero : diff);
  }

  String _formatCountdown() {
    final h = _remaining.inHours;
    final m = _remaining.inMinutes % 60;
    if (h > 0) return '${h}h ${m}m remaining';
    return '${_remaining.inMinutes}m ${_remaining.inSeconds % 60}s remaining';
  }

  Future<void> _castVote(String vote) async {
    setState(() => _isSubmitting = true);
    try {
      await Supabase.instance.client.rpc('ubi_cast_vote', params: {
        'p_assignment_id': widget.assignmentId,
        'p_vote': vote,
      });

      setState(() => _voteSubmitted = vote);
      ref.invalidate(ubiAssignmentDetailProvider(widget.assignmentId));
      ref.invalidate(myUbiAssignmentsProvider);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Vote failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final detailAsync = ref.watch(ubiAssignmentDetailProvider(widget.assignmentId));

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: const Text('Community Vote',
            style: TextStyle(color: AppTheme.textPrimary)),
        iconTheme: const IconThemeData(color: AppTheme.textPrimary),
      ),
      body: detailAsync.when(
        data: (detail) {
          if (detail == null) {
            return const Center(
              child: Text('Vote not found.',
                  style: TextStyle(color: AppTheme.textSecondary)),
            );
          }

          final assignment = UbiPanelAssignment.fromJson(
              detail['assignment'] as Map<String, dynamic>);
          final panel = detail['panel'] != null
              ? UbiVotingPanel.fromJson(detail['panel'] as Map<String, dynamic>)
              : null;
          final request = detail['request'] as Map<String, dynamic>?;
          final voterSummary = detail['voter_summary'] as String?;
          final amountCents = (request?['amount_requested_usd_cents'] as num?)?.toInt() ?? 0;
          final category = request?['emergency_category'] as String? ?? 'other';
          final dollars = (amountCents / 100).toStringAsFixed(0);
          final hasVoted = assignment.assignmentStatus == 'voted' || _voteSubmitted != null;
          final isPanelClosed = panel?.isClosed ?? false;
          final deadline = panel?.effectiveDeadline;

          if (deadline != null && _remaining == Duration.zero) {
            Future.microtask(() => _startCountdown(deadline));
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // ── Header ───────────────────────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.cardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Emergency Fund Request · \$$dollars · ${category[0].toUpperCase()}${category.substring(1)}',
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 13),
                    ),
                    if (!isPanelClosed && deadline != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Row(
                          children: [
                            const Icon(Icons.timer, color: AppTheme.primary, size: 14),
                            const SizedBox(width: 4),
                            Text(_formatCountdown(),
                                style: const TextStyle(
                                    color: AppTheme.primary, fontSize: 13)),
                          ],
                        ),
                      ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // ── AI voter summary ──────────────────────────────────────────────
              Container(
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: AppTheme.cardBorder),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('About This Request',
                        style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontWeight: FontWeight.bold,
                            fontSize: 15)),
                    const SizedBox(height: 8),
                    Text(
                      voterSummary ??
                          'Summary not yet available. Please check back shortly.',
                      style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 14,
                          height: 1.5),
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      'This is a privacy-protected summary. The applicant\'s '
                      'identity is not disclosed to voters.',
                      style: TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                          fontStyle: FontStyle.italic),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 16),

              // ── Vote results (shown after panel closes) ───────────────────────
              if (isPanelClosed && panel != null) ...[
                _VoteResultCard(panel: panel),
                const SizedBox(height: 16),
              ],

              // ── Vote buttons ──────────────────────────────────────────────────
              if (!hasVoted && !isPanelClosed) ...[
                const Text(
                  'Your vote is anonymous. Results are hidden until voting closes.',
                  style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _isSubmitting
                            ? null
                            : () => _castVote('yes'),
                        icon: const Icon(Icons.check_circle_outline),
                        label: const Text('Approve'),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.success,
                          minimumSize: const Size(0, 52),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: _isSubmitting
                            ? null
                            : () => _castVote('no'),
                        icon: const Icon(Icons.cancel_outlined),
                        label: const Text('Deny'),
                        style: FilledButton.styleFrom(
                          backgroundColor: AppTheme.danger,
                          minimumSize: const Size(0, 52),
                        ),
                      ),
                    ),
                  ],
                ),
              ] else if (hasVoted && !isPanelClosed) ...[
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppTheme.success.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                        color: AppTheme.success.withValues(alpha: 0.3)),
                  ),
                  child: const Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.check_circle, color: AppTheme.success),
                      SizedBox(width: 8),
                      Text('Vote recorded. Results revealed when voting closes.',
                          style: TextStyle(
                              color: AppTheme.success, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ],
            ],
          );
        },
        loading: () => const Center(
            child: CircularProgressIndicator(color: AppTheme.primary)),
        error: (e, _) => Center(
            child:
                Text('$e', style: const TextStyle(color: AppTheme.danger))),
      ),
    );
  }
}

class _VoteResultCard extends StatelessWidget {
  final UbiVotingPanel panel;

  const _VoteResultCard({required this.panel});

  @override
  Widget build(BuildContext context) {
    final yes = panel.votesYes ?? 0;
    final total = panel.votesReceived ?? 0;
    final outcome = panel.outcome ?? 'inconclusive';
    final outcomeColor = switch (outcome) {
      'approved' => AppTheme.success,
      'denied' => AppTheme.danger,
      _ => AppTheme.textSecondary,
    };
    final outcomeLabel = switch (outcome) {
      'approved' => 'Approved',
      'denied' => 'Not Approved',
      _ => 'Inconclusive',
    };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: outcomeColor.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: outcomeColor.withValues(alpha: 0.3)),
      ),
      child: Column(
        children: [
          Text('Final Result',
              style: TextStyle(
                  color: outcomeColor,
                  fontWeight: FontWeight.bold,
                  fontSize: 13)),
          const SizedBox(height: 6),
          Text(outcomeLabel,
              style: TextStyle(
                  color: outcomeColor,
                  fontSize: 22,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 6),
          if (total > 0)
            Text(
              '$yes of $total voted yes  (${(yes / total * 100).toStringAsFixed(0)}%)',
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
        ],
      ),
    );
  }
}
