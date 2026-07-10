import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../models/ubi_models.dart';
import '../providers/ubi_providers.dart';
import '../../../core/widgets/n_back_button.dart';

class MyRequestsScreen extends ConsumerWidget {
  const MyRequestsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final requestsAsync = ref.watch(myUbiRequestsProvider);
    final assignmentsAsync = ref.watch(myUbiAssignmentsProvider);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: const NBackButton(fallback: '/emergency-fund'),
        backgroundColor: AppTheme.surface,
        title: const Text('Emergency Fund',
            style: TextStyle(color: AppTheme.textPrimary)),
        iconTheme: const IconThemeData(color: AppTheme.textPrimary),
      ),
      body: RefreshIndicator(
        color: AppTheme.primary,
        backgroundColor: AppTheme.surface,
        onRefresh: () async {
          ref.invalidate(myUbiRequestsProvider);
          ref.invalidate(myUbiAssignmentsProvider);
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ── Vote assignments ──────────────────────────────────────────────
            assignmentsAsync.when(
              data: (assignments) => assignments.isEmpty
                  ? const SizedBox.shrink()
                  : _Section(
                      title: 'Pending Votes',
                      child: Column(
                        children: assignments
                            .map((a) => _AssignmentTile(assignment: a))
                            .toList(),
                      ),
                    ),
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),

            // ── My requests ───────────────────────────────────────────────────
            requestsAsync.when(
              data: (requests) => requests.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(vertical: 48),
                        child: Column(
                          children: [
                            const Icon(Icons.inbox_outlined,
                                color: AppTheme.textSecondary, size: 48),
                            const SizedBox(height: 12),
                            const Text("You haven't submitted any requests.",
                                style: TextStyle(color: AppTheme.textSecondary)),
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: () =>
                                  context.push('/emergency-fund/request'),
                              style: FilledButton.styleFrom(
                                  backgroundColor: AppTheme.primary),
                              child: const Text('Request Funds'),
                            ),
                          ],
                        ),
                      ),
                    )
                  : _Section(
                      title: 'My Requests',
                      child: Column(
                        children: requests
                            .map((r) => _RequestTile(request: r))
                            .toList(),
                      ),
                    ),
              loading: () => const Center(
                  child: CircularProgressIndicator(color: AppTheme.primary)),
              error: (e, _) =>
                  Text('$e', style: const TextStyle(color: AppTheme.danger)),
            ),
          ],
        ),
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => context.push('/emergency-fund/request'),
        backgroundColor: AppTheme.primary,
        label: const Text('New Request'),
        icon: const Icon(Icons.add),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final Widget child;

  const _Section({required this.title, required this.child});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(title,
              style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
        ),
        child,
        const SizedBox(height: 20),
      ],
    );
  }
}

class _AssignmentTile extends StatelessWidget {
  final UbiPanelAssignment assignment;

  const _AssignmentTile({required this.assignment});

  @override
  Widget build(BuildContext context) {
    return Card(
      color: AppTheme.primary.withValues(alpha: 0.08),
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: AppTheme.primary.withValues(alpha: 0.3)),
      ),
      child: ListTile(
        leading: const Icon(Icons.how_to_vote, color: AppTheme.primary),
        title: const Text('Community Vote Pending',
            style: TextStyle(
                color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
        subtitle: const Text('You have been selected to vote on an Emergency Fund request.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
        trailing: FilledButton(
          onPressed: () =>
              context.push('/emergency-fund/vote/${assignment.id}'),
          style: FilledButton.styleFrom(
            backgroundColor: AppTheme.primary,
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
          child: const Text('Vote'),
        ),
      ),
    );
  }
}

class _RequestTile extends StatelessWidget {
  final UbiWithdrawalRequest request;

  const _RequestTile({required this.request});

  @override
  Widget build(BuildContext context) {
    final dollars = (request.amountRequestedCents / 100).toStringAsFixed(0);
    final category = request.emergencyCategory[0].toUpperCase() +
        request.emergencyCategory.substring(1);
    final statusColor = switch (request.status) {
      'approved' || 'disbursed' => AppTheme.success,
      'denied' || 'revote_denied' || 'voided' => AppTheme.danger,
      'voting' || 'revote_voting' => AppTheme.primary,
      _ => AppTheme.textSecondary,
    };

    return Card(
      color: AppTheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: AppTheme.cardBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$category · \$$dollars',
                      style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 15)),
                  const SizedBox(height: 4),
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: statusColor.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      request.statusLabel,
                      style: TextStyle(
                          color: statusColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w600),
                    ),
                  ),
                  if (request.submittedAt != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Text(
                        'Submitted ${_formatDate(request.submittedAt!)}',
                        style: const TextStyle(
                            color: AppTheme.textSecondary, fontSize: 11),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.month}/${dt.day}/${dt.year}';
  }
}
