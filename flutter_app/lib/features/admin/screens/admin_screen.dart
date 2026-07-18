import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/n_back_button.dart';

/// Admin operations console (MVP — PLAN 2026-07-15 callout). Two surfaces:
/// the moderation review queue (held cutscenes + open escalations +
/// similarity-flagged clips) and stuck mint jobs. Every action is re-gated
/// server-side by the admin-review edge function (profiles.is_admin) — this
/// screen is only a window; a non-admin gets a 403 and the locked state.
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  Map<String, dynamic>? _queue;
  List<Map<String, dynamic>> _jobs = const [];
  bool _loading = true;
  bool _forbidden = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<Map<String, dynamic>> _get(String action) async {
    final res = await Supabase.instance.client.functions.invoke(
      'admin-review',
      method: HttpMethod.get,
      queryParameters: {'action': action},
    );
    return Map<String, dynamic>.from(res.data as Map);
  }

  Future<void> _post(Map<String, dynamic> body) async {
    await Supabase.instance.client.functions.invoke('admin-review', body: body);
  }

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final queue = await _get('queue');
      final jobs = await _get('jobs');
      if (!mounted) return;
      setState(() {
        _queue = queue;
        _jobs = ((jobs['jobs'] as List?) ?? const [])
            .map((j) => Map<String, dynamic>.from(j as Map))
            .toList();
      });
    } on FunctionException catch (e) {
      if (!mounted) return;
      setState(() => e.status == 403
          ? _forbidden = true
          : _error = 'Could not load: ${e.status}');
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not load: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// Runs an admin action with a spinner + error snackbar, then refreshes.
  Future<void> _act(Map<String, dynamic> body) async {
    setState(() => _loading = true);
    try {
      await _post(body);
    } on FunctionException catch (e) {
      if (mounted) {
        final detail = (e.details is Map ? (e.details as Map)['error'] : null) ??
            'failed (${e.status})';
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Action $detail'), backgroundColor: AppTheme.danger));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Action failed — $e'),
            backgroundColor: AppTheme.danger));
      }
    }
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        backgroundColor: AppTheme.background,
        appBar: AppBar(
          leading: const NBackButton(fallback: '/home'),
          backgroundColor: AppTheme.background,
          title: const Text('Admin · Operations'),
          actions: [
            IconButton(
                onPressed: _loading ? null : _refresh,
                icon: const Icon(Icons.refresh)),
          ],
          bottom: const TabBar(
            indicatorColor: AppTheme.primary,
            labelColor: AppTheme.textPrimary,
            unselectedLabelColor: AppTheme.textSecondary,
            tabs: [
              Tab(text: 'Review queue'),
              Tab(text: 'Mint jobs'),
            ],
          ),
        ),
        body: _forbidden
            ? const Center(
                child: Text('Admin access required',
                    style: TextStyle(color: AppTheme.textSecondary)))
            : _loading && _queue == null
                ? const Center(
                    child:
                        CircularProgressIndicator(color: AppTheme.primary))
                : _error != null
                    ? Center(
                        child: Text(_error!,
                            style: const TextStyle(color: AppTheme.danger)))
                    : TabBarView(children: [_reviewTab(), _jobsTab()]),
      ),
    );
  }

  // ── Review queue tab ──────────────────────────────────────────────────────
  Widget _reviewTab() {
    final held = ((_queue?['held'] as List?) ?? const [])
        .map((g) => Map<String, dynamic>.from(g as Map))
        .toList();
    final escalations = ((_queue?['escalations'] as List?) ?? const [])
        .map((g) => Map<String, dynamic>.from(g as Map))
        .toList();
    final flagged = ((_queue?['flagged_clips'] as List?) ?? const [])
        .map((g) => Map<String, dynamic>.from(g as Map))
        .toList();

    if (held.isEmpty && escalations.isEmpty && flagged.isEmpty) {
      return const Center(
          child: Text('Queue is clear 🎉',
              style: TextStyle(color: AppTheme.textSecondary)));
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (held.isNotEmpty) _sectionTitle('Held cutscenes (${held.length})'),
          ...held.map(_heldCard),
          if (flagged.isNotEmpty)
            _sectionTitle('Similarity-flagged clips (${flagged.length})'),
          ...flagged.map(_flaggedClipCard),
          if (escalations.isNotEmpty)
            _sectionTitle('Open escalations (${escalations.length})'),
          ...escalations.map(_escalationCard),
        ],
      ),
    );
  }

  Widget _sectionTitle(String t) => Padding(
        padding: const EdgeInsets.only(bottom: 10, top: 6),
        child: Text(t,
            style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700)),
      );

  Widget _card({required List<Widget> children}) => Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Column(
            crossAxisAlignment: CrossAxisAlignment.start, children: children),
      );

  Widget _meta(String s) => Text(s,
      style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12));

  Widget _heldCard(Map<String, dynamic> g) {
    final m = (g['moments'] as Map?)?.cast<String, dynamic>() ?? const {};
    final frames = ((g['frames'] as List?) ?? const []).cast<String>();
    final rejected = g['status'] == 'moderation_rejected';
    return _card(children: [
      Row(children: [
        Icon(rejected ? Icons.block : Icons.hourglass_top,
            size: 16, color: rejected ? AppTheme.danger : AppTheme.secondary),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '${m['creator_handle'] ?? 'unknown'} · ${m['source_platform'] ?? ''}'
            '${rejected ? ' · REJECTED (${g['reject_reason']})' : ' · awaiting verdict'}',
            style: const TextStyle(
                color: AppTheme.textPrimary, fontWeight: FontWeight.w600),
          ),
        ),
      ]),
      const SizedBox(height: 6),
      _meta('"${g['requested_name'] ?? g['subject_desc'] ?? ''}" · '
          'attempt ${g['attempt']} · ${g['v2v_provider'] ?? 'seedance'} · '
          '${g['created_at']}'),
      if (frames.isNotEmpty) ...[
        const SizedBox(height: 10),
        SizedBox(
          height: 90,
          child: ListView(
            scrollDirection: Axis.horizontal,
            children: frames
                .map((u) => Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(8),
                        child: Image.network(u,
                            height: 90,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => Container(
                                width: 120,
                                color: AppTheme.surfaceLight,
                                child: const Icon(Icons.broken_image,
                                    color: AppTheme.textSecondary))),
                      ),
                    ))
                .toList(),
          ),
        ),
      ],
      const SizedBox(height: 10),
      Row(children: [
        if (!rejected) ...[
          FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.success),
            onPressed: () => _act({
              'action': 'verdict',
              'generation_id': g['id'],
              'approved': true,
            }),
            icon: const Icon(Icons.check, size: 16),
            label: const Text('Approve'),
          ),
          const SizedBox(width: 8),
          OutlinedButton.icon(
            style:
                OutlinedButton.styleFrom(foregroundColor: AppTheme.danger),
            onPressed: () => _act({
              'action': 'verdict',
              'generation_id': g['id'],
              'approved': false,
              'reason': 'admin_review',
            }),
            icon: const Icon(Icons.close, size: 16),
            label: const Text('Reject'),
          ),
        ] else
          OutlinedButton.icon(
            onPressed: () =>
                _act({'action': 'reopen', 'generation_id': g['id']}),
            icon: const Icon(Icons.replay, size: 16),
            label: const Text('Reopen for verdict'),
          ),
      ]),
    ]);
  }

  Widget _flaggedClipCard(Map<String, dynamic> m) {
    return _card(children: [
      Text(
          '${m['creator_handle'] ?? 'unknown'} · ${m['source_platform'] ?? ''} '
          '· clip didn\'t match the linked post',
          style: const TextStyle(
              color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      _meta('${m['source_url'] ?? ''} · flagged ${m['clip_attached_at'] ?? ''}'),
      const SizedBox(height: 10),
      Row(children: [
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppTheme.success),
          onPressed: () => _act({
            'action': 'clip_verdict',
            'moment_id': m['id'],
            'approved': true,
          }),
          child: const Text('Clip is fine — attach'),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger),
          onPressed: () => _act({
            'action': 'clip_verdict',
            'moment_id': m['id'],
            'approved': false,
          }),
          child: const Text('Reject clip'),
        ),
      ]),
    ]);
  }

  Widget _escalationCard(Map<String, dynamic> e) {
    final m = (e['moments'] as Map?)?.cast<String, dynamic>() ?? const {};
    return _card(children: [
      Text('${e['reason']} · ${m['creator_handle'] ?? 'unknown'}',
          style: const TextStyle(
              color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      _meta('${m['source_url'] ?? ''} · opened ${e['created_at']}'),
      const SizedBox(height: 4),
      _meta(e['reason'] == 'minor_safety'
          ? 'Clearing a minor-safety case never auto-approves the moment.'
          : 'Review-only flag — the moment stays approved either way.'),
      const SizedBox(height: 10),
      Row(children: [
        OutlinedButton(
          onPressed: () => _act({
            'action': 'resolve_escalation',
            'escalation_id': e['id'],
            'cleared': true,
          }),
          child: const Text('Resolve — cleared'),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger),
          onPressed: () => _act({
            'action': 'resolve_escalation',
            'escalation_id': e['id'],
            'cleared': false,
          }),
          child: const Text('Resolve — blocked'),
        ),
      ]),
    ]);
  }

  // ── Mint jobs tab ─────────────────────────────────────────────────────────
  Widget _jobsTab() {
    if (_jobs.isEmpty) {
      return const Center(
          child: Text('No live or recently-failed jobs',
              style: TextStyle(color: AppTheme.textSecondary)));
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: _jobs.map((j) {
          final stale = j['stale'] == true;
          final running = j['status'] == 'running';
          return _card(children: [
            Row(children: [
              Icon(
                  running
                      ? (stale ? Icons.warning_amber : Icons.autorenew)
                      : Icons.error_outline,
                  size: 16,
                  color: running
                      ? (stale ? AppTheme.danger : AppTheme.secondary)
                      : AppTheme.textSecondary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                    '${j['status']}${stale ? ' (STALE)' : ''} · stage ${j['stage'] ?? '—'}',
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontWeight: FontWeight.w600)),
              ),
            ]),
            const SizedBox(height: 6),
            _meta('job ${j['id']}'),
            _meta('moment ${j['moment_id']} · user ${j['user_id']}'),
            _meta('updated ${j['updated_at']}'
                '${j['detail'] != null ? ' · ${j['detail']}' : ''}'),
            if (running && stale) ...[
              const SizedBox(height: 10),
              OutlinedButton(
                style:
                    OutlinedButton.styleFrom(foregroundColor: AppTheme.danger),
                onPressed: () => _act({'action': 'fail_job', 'job_id': j['id']}),
                child: const Text('Mark failed (lets the user retry)'),
              ),
            ],
          ]);
        }).toList(),
      ),
    );
  }
}
