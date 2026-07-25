import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher_string.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/n_back_button.dart';

/// Admin operations console (PLAN 2026-07-15 callout; iteration 2, mig 168).
/// Five surfaces: the moderation review queue, mint-job ops, user/account ops
/// (flags + audited token adjustments), config kill-switches, and marketplace
/// dispute delisting. Every action is re-gated server-side by the admin-review
/// edge function (profiles.is_admin) — this screen is only a window; a
/// non-admin gets a 403 and the locked state.
class AdminScreen extends StatefulWidget {
  const AdminScreen({super.key});

  @override
  State<AdminScreen> createState() => _AdminScreenState();
}

class _AdminScreenState extends State<AdminScreen> {
  Map<String, dynamic>? _queue;
  List<Map<String, dynamic>> _jobs = const [];
  Map<String, dynamic>? _config;
  List<Map<String, dynamic>> _listings = const [];
  List<Map<String, dynamic>> _users = const [];
  Map<String, dynamic>? _campaigns;
  List<Map<String, dynamic>> _audit = const [];
  final _userSearch = TextEditingController();
  bool _searching = false;
  bool _loading = true;
  bool _forbidden = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _userSearch.dispose();
    super.dispose();
  }

  Future<Map<String, dynamic>> _get(String action,
      [Map<String, dynamic>? params]) async {
    final res = await Supabase.instance.client.functions.invoke(
      'admin-review',
      method: HttpMethod.get,
      queryParameters: {'action': action, ...?params},
    );
    return Map<String, dynamic>.from(res.data as Map);
  }

  Future<void> _post(Map<String, dynamic> body) async {
    await Supabase.instance.client.functions.invoke('admin-review', body: body);
  }

  List<Map<String, dynamic>> _asList(dynamic v) => ((v as List?) ?? const [])
      .map((e) => Map<String, dynamic>.from(e as Map))
      .toList();

  Future<void> _refresh() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final queue = await _get('queue');
      final jobs = await _get('jobs');
      final config = await _get('config');
      final listings = await _get('listings');
      final campaigns = await _get('campaigns');
      final audit = await _get('audit');
      if (!mounted) return;
      setState(() {
        _queue = queue;
        _jobs = _asList(jobs['jobs']);
        _config = config;
        _listings = _asList(listings['listings']);
        _campaigns = campaigns;
        _audit = _asList(audit['entries']);
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
    // Keep the user search results current after any user-affecting action.
    if (_userSearch.text.trim().isNotEmpty) await _search();
  }

  Future<void> _search() async {
    final q = _userSearch.text.trim();
    if (q.isEmpty) {
      setState(() => _users = const []);
      return;
    }
    setState(() => _searching = true);
    try {
      final res = await _get('users', {'q': q});
      if (mounted) setState(() => _users = _asList(res['users']));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text('Search failed — $e'),
            backgroundColor: AppTheme.danger));
      }
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 7,
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
            isScrollable: true,
            tabs: [
              Tab(text: 'Review queue'),
              Tab(text: 'Mint jobs'),
              Tab(text: 'Users'),
              Tab(text: 'Campaigns'),
              Tab(text: 'Config'),
              Tab(text: 'Market'),
              Tab(text: 'Audit'),
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
                    : TabBarView(children: [
                        _reviewTab(),
                        _jobsTab(),
                        _usersTab(),
                        _campaignsTab(),
                        _configTab(),
                        _marketTab(),
                        _auditTab(),
                      ]),
      ),
    );
  }

  // ── Shared bits ───────────────────────────────────────────────────────────
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

  Widget _chip(String label, Color color) => Container(
        margin: const EdgeInsets.only(right: 6),
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.13),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: color.withValues(alpha: 0.45)),
        ),
        child: Text(label,
            style: TextStyle(
                color: color, fontSize: 9, fontWeight: FontWeight.w800)),
      );

  // ── Review queue tab ──────────────────────────────────────────────────────
  Widget _reviewTab() {
    final held = _asList(_queue?['held']);
    final escalations = _asList(_queue?['escalations']);
    final flagged = _asList(_queue?['flagged_clips']);

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

  // ── Users tab (iteration 2) ───────────────────────────────────────────────
  Widget _usersTab() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        TextField(
          controller: _userSearch,
          onSubmitted: (_) => _search(),
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14),
          decoration: InputDecoration(
            hintText: 'Search by username, display name, or user id…',
            hintStyle:
                const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            prefixIcon: const Icon(Icons.search,
                size: 18, color: AppTheme.textSecondary),
            suffixIcon: IconButton(
              onPressed: _searching ? null : _search,
              icon: _searching
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.arrow_forward, size: 18),
            ),
            isDense: true,
            filled: true,
            fillColor: AppTheme.surface,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppTheme.cardBorder),
            ),
          ),
        ),
        const SizedBox(height: 14),
        if (_users.isEmpty)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 24),
            child: Text(
                'Look up an account to see flags, KYC status, and balance — '
                'and to make audited token adjustments.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
          ),
        ..._users.map(_userCard),
      ],
    );
  }

  Widget _userCard(Map<String, dynamic> u) {
    final balance =
        ((u['token_balances'] as Map?)?['available_tokens'] as num?)?.toInt();
    final kyc = (u['kyc_status'] ?? 'none').toString();
    final isTest = u['is_test_account'] == true;
    return _card(children: [
      Text(
          (u['display_name'] ?? u['username'] ?? 'unnamed').toString() +
              ((u['username'] != null && u['display_name'] != null)
                  ? ' · @${u['username']}'
                  : ''),
          style: const TextStyle(
              color: AppTheme.textPrimary, fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      SelectableText(u['id'].toString(),
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
      const SizedBox(height: 8),
      Wrap(runSpacing: 4, children: [
        if (u['is_admin'] == true) _chip('ADMIN', AppTheme.primary),
        if (isTest) _chip('TEST', AppTheme.danger),
        if (u['is_market_maker'] == true) _chip('MARKET MAKER', AppTheme.secondary),
        _chip(
            'KYC: ${kyc.toUpperCase()}',
            kyc == 'approved'
                ? AppTheme.success
                : kyc == 'none'
                    ? AppTheme.textSecondary
                    : const Color(0xFFFFC53D)),
        _chip('${balance ?? '—'} 🪙', AppTheme.success),
        if ((u['active_listings'] as num? ?? 0) > 0)
          _chip('${u['active_listings']} LISTED', AppTheme.secondary),
      ]),
      const SizedBox(height: 10),
      Row(children: [
        OutlinedButton.icon(
          onPressed: () => _adjustTokensDialog(u),
          icon: const Icon(Icons.tune, size: 16),
          label: const Text('Adjust tokens'),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          style: OutlinedButton.styleFrom(
              foregroundColor:
                  isTest ? AppTheme.textSecondary : AppTheme.danger),
          onPressed: () => _act({
            'action': 'set_test_flag',
            'user_id': u['id'],
            'is_test': !isTest,
          }),
          child: Text(isTest ? 'Unmark test account' : 'Mark test account'),
        ),
      ]),
    ]);
  }

  Future<void> _adjustTokensDialog(Map<String, dynamic> u) async {
    final amount = TextEditingController();
    final note = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Adjust tokens — ${u['display_name'] ?? u['username']}',
            style:
                const TextStyle(color: AppTheme.textPrimary, fontSize: 16)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: amount,
            autofocus: true,
            keyboardType: const TextInputType.numberWithOptions(signed: true),
            style: const TextStyle(color: AppTheme.textPrimary),
            decoration: const InputDecoration(
                labelText: 'Delta (e.g. 500 or -500)',
                helperText: 'Negative claws back; can\'t overdraw.'),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: note,
            style: const TextStyle(color: AppTheme.textPrimary),
            decoration: const InputDecoration(
                labelText: 'Why? (required, lands in the audit ledger)'),
          ),
        ]),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Apply')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    final delta = int.tryParse(amount.text.trim());
    if (delta == null || delta == 0 || note.text.trim().isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('A non-zero integer delta and a note are required.'),
          backgroundColor: AppTheme.danger));
      return;
    }
    await _act({
      'action': 'adjust_tokens',
      'user_id': u['id'],
      'delta': delta,
      'note': note.text.trim(),
    });
  }

  // ── Campaigns tab (iteration 3) ───────────────────────────────────────────
  /// The Clip Campaigns review queue. mig 176 keeps campaign-clip escalations in
  /// their own table (moderation_escalations.moment_id is NOT NULL and FK'd to
  /// moments, and a campaign clip has no moment), so this is the second queue —
  /// without it, escalated campaign clips pile up unreviewed.
  Widget _campaignsTab() {
    final escalations = _asList(_campaigns?['escalations']);
    final pending = _asList(_campaigns?['pending']);
    final overdue = _asList(_campaigns?['overdue']);

    if (escalations.isEmpty && pending.isEmpty && overdue.isEmpty) {
      return const Center(
          child: Text('No campaign clips need attention 🎉',
              style: TextStyle(color: AppTheme.textSecondary)));
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (escalations.isNotEmpty)
            _sectionTitle('Clip escalations (${escalations.length})'),
          ...escalations.map(_clipEscalationCard),
          if (pending.isNotEmpty)
            _sectionTitle('Awaiting a verdict (${pending.length})'),
          ...pending.map(_pendingClipCard),
          if (overdue.isNotEmpty) ...[
            _sectionTitle('Overdue, still holding escrow (${overdue.length})'),
            _card(children: [
              const Text(
                  'These campaigns are past their deadline but still hold '
                  'escrow. The hourly sweep should clear them — if they persist, '
                  'the cron job is not running.',
                  style:
                      TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
              const SizedBox(height: 10),
              for (final c in overdue)
                Padding(
                  padding: const EdgeInsets.only(bottom: 4),
                  child: _meta(
                      '${c['title']} · '
                      '\$${(((c['escrow_remaining_cents'] as num?) ?? 0) / 100).toStringAsFixed(2)} held · '
                      'due ${c['deadline']}'),
                ),
              const SizedBox(height: 10),
              FilledButton.icon(
                onPressed: () => _act({'action': 'expire_campaigns'}),
                icon: const Icon(Icons.cleaning_services_outlined, size: 16),
                label: const Text('Run the refund sweep now'),
              ),
            ]),
          ],
        ],
      ),
    );
  }

  Widget _clipEscalationCard(Map<String, dynamic> e) {
    final sub = (e['clip_campaign_submissions'] as Map?)?.cast<String, dynamic>() ??
        const {};
    final camp =
        (sub['clip_campaigns'] as Map?)?.cast<String, dynamic>() ?? const {};
    final minorSafety = e['reason'] == 'minor_safety';
    final clipUrl = e['clip_url'] as String?;
    return _card(children: [
      Row(children: [
        Icon(minorSafety ? Icons.gpp_maybe : Icons.flag_outlined,
            size: 16, color: minorSafety ? AppTheme.danger : AppTheme.secondary),
        const SizedBox(width: 6),
        Expanded(
          child: Text('${e['reason']} · ${camp['title'] ?? 'campaign'}',
              style: const TextStyle(
                  color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
        ),
      ]),
      const SizedBox(height: 6),
      _meta('submission ${e['submission_id']} · opened ${e['created_at']}'),
      _meta('clipper ${sub['clipper_user_id'] ?? 'unknown'} · '
          'status ${sub['status'] ?? '—'}'),
      const SizedBox(height: 4),
      _meta(minorSafety
          ? 'Minor-safety is absolute: this clip can never be approved from the '
              'console, whatever the case resolution says.'
          : 'Review-only flag — resolving does not change the clip verdict.'),
      const SizedBox(height: 10),
      Wrap(spacing: 8, runSpacing: 8, children: [
        if (clipUrl != null)
          OutlinedButton.icon(
            onPressed: () => _openUrl(clipUrl),
            icon: const Icon(Icons.play_circle_outline, size: 16),
            label: const Text('Watch clip'),
          ),
        OutlinedButton(
          onPressed: () => _act({
            'action': 'resolve_clip_escalation',
            'escalation_id': e['id'],
            'cleared': true,
          }),
          child: const Text('Resolve — cleared'),
        ),
        OutlinedButton(
          style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger),
          onPressed: () => _act({
            'action': 'resolve_clip_escalation',
            'escalation_id': e['id'],
            'cleared': false,
          }),
          child: const Text('Resolve — blocked'),
        ),
        OutlinedButton(
          style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger),
          onPressed: () => _act({
            'action': 'clip_submission_verdict',
            'submission_id': e['submission_id'],
            'approved': false,
          }),
          child: const Text('Reject the clip'),
        ),
      ]),
    ]);
  }

  Widget _pendingClipCard(Map<String, dynamic> s) {
    final camp =
        (s['clip_campaigns'] as Map?)?.cast<String, dynamic>() ?? const {};
    return _card(children: [
      Text('${camp['title'] ?? 'campaign'} · ${s['status']}',
          style: const TextStyle(
              color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
      const SizedBox(height: 6),
      _meta('submission ${s['id']} · submitted ${s['created_at']}'),
      if (s['note'] != null) _meta('note: ${s['note']}'),
      const SizedBox(height: 4),
      _meta('Never got a verdict — usually moderation was rate-limited '
          'mid-flight. The Market Maker cannot see it in this state.'),
      const SizedBox(height: 10),
      Row(children: [
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppTheme.success),
          onPressed: () => _act({
            'action': 'clip_submission_verdict',
            'submission_id': s['id'],
            'approved': true,
          }),
          child: const Text('Approve'),
        ),
        const SizedBox(width: 8),
        OutlinedButton(
          style: OutlinedButton.styleFrom(foregroundColor: AppTheme.danger),
          onPressed: () => _act({
            'action': 'clip_submission_verdict',
            'submission_id': s['id'],
            'approved': false,
          }),
          child: const Text('Reject'),
        ),
      ]),
    ]);
  }

  void _openUrl(String url) {
    // Signed review URLs are short-lived; open in a new tab rather than caching.
    launchUrlString(url);
  }

  // ── Audit tab (iteration 3) ───────────────────────────────────────────────
  Widget _auditTab() {
    if (_audit.isEmpty) {
      return const Center(
          child: Text('No admin actions recorded yet',
              style: TextStyle(color: AppTheme.textSecondary)));
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _card(children: [
            const Text(
                'Every console action is recorded here, append-only. Rows can '
                'never be edited or deleted — a flipped founder gate stays '
                'attributable.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
          ]),
          ..._audit.map((a) => _card(children: [
                Text('${a['action']} · ${a['admin_name']}',
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                _meta('${a['created_at']}'),
                if (a['target_id'] != null) _meta('target ${a['target_id']}'),
                if (a['detail'] != null) _meta('${a['detail']}'),
              ])),
        ],
      ),
    );
  }

  // ── Config tab (iteration 2) ──────────────────────────────────────────────
  Widget _configTab() {
    final settings =
        (_config?['settings'] as Map?)?.cast<String, dynamic>() ?? const {};
    final counts =
        (_config?['counts'] as Map?)?.cast<String, dynamic>() ?? const {};
    final pricing = _asList(_config?['tier_pricing']);
    final mysteryMode =
        (_config?['mystery_pool_mode'] ?? 'disabled').toString();

    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _sectionTitle('Right now'),
          _card(children: [
            _meta('Held cutscenes: ${counts['held_generations'] ?? '—'}'),
            _meta('Open escalations: ${counts['open_escalations'] ?? '—'}'),
            _meta('Running mint jobs: ${counts['running_jobs'] ?? '—'}'),
            _meta('Active listings: ${counts['active_listings'] ?? '—'}'),
            _meta('Open clip escalations: '
                '${counts['open_clip_escalations'] ?? '—'}'),
            _meta('Campaign clips awaiting a verdict: '
                '${counts['pending_clip_submissions'] ?? '—'}'),
            _meta('Overdue campaigns holding escrow: '
                '${counts['overdue_campaigns'] ?? '—'}'),
          ]),
          _sectionTitle('Integrity + money gates'),
          _card(children: [
            const Text(
                'These are the live-launch switches (platform_integrity_'
                'settings). Every flip takes effect immediately.',
                style:
                    TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
            const SizedBox(height: 6),
            _settingSwitch(settings, 'require_kyc_for_staking',
                'Require KYC to stake (bets)'),
            _settingSwitch(settings, 'require_kyc_for_combatant',
                'Require KYC to be a combatant'),
            _settingSwitch(settings, 'marketplace_usd_lane',
                'Marketplace USD lane (founder gate)',
                danger: true),
            const Divider(color: AppTheme.cardBorder),
            SwitchListTile(
              value: settings['enforce_one_role_per_match'] == true,
              onChanged: null, // never toggleable — integrity invariant
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('One role per match (locked ON)',
                  style:
                      TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
              subtitle: const Text(
                  'Money-independent integrity — not toggleable from anywhere.',
                  style:
                      TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
            ),
            const Divider(color: AppTheme.cardBorder),
            Row(children: [
              const Expanded(
                child: Text('Battle payments mode',
                    style: TextStyle(
                        color: AppTheme.textPrimary, fontSize: 13)),
              ),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'sim', label: Text('sim')),
                  ButtonSegment(value: 'live', label: Text('live')),
                ],
                selected: {
                  (settings['battle_payments_mode'] ?? 'sim').toString()
                },
                onSelectionChanged: (sel) => _confirmToggle(
                  'battle_payments_mode',
                  sel.first,
                  'Switch battle payments to ${sel.first.toUpperCase()}?',
                  sel.first == 'live'
                      ? 'LIVE moves real USD on the Treasury rail. Only flip '
                          'when Stripe prereqs are in place.'
                      : 'SIM settles against simulated balances.',
                ),
              ),
            ]),
          ]),
          _sectionTitle('Mystery Box gate (G-MYSTERY)'),
          _card(children: [
            const Text(
                'Beta ships DISABLED: submissions and awards both refuse while '
                'this is off. Boxes are never sellable in any mode — that is '
                'structural, not a setting.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
            const SizedBox(height: 8),
            Row(children: [
              const Expanded(
                child: Text('Mystery pool mode',
                    style:
                        TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
              ),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'disabled', label: Text('off')),
                  ButtonSegment(value: 'sim', label: Text('sim')),
                  ButtonSegment(value: 'live', label: Text('live')),
                ],
                selected: {mysteryMode},
                onSelectionChanged: (sel) => _confirmMysteryMode(sel.first),
              ),
            ]),
          ]),
          _sectionTitle('Marketplace tier pricing (config — read-only here)'),
          _card(children: [
            for (final p in pricing)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Row(children: [
                  SizedBox(
                      width: 24,
                      child: Text(p['tier'].toString(),
                          style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontWeight: FontWeight.w800))),
                  Text('${p['token_price']} 🪙',
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 12)),
                  const Spacer(),
                  Text(
                      (p['fee_bps'] as num? ?? 0) > 0
                          ? 'fee ${(p['fee_bps'] as num) / 100}% (burned)'
                          : 'no fee',
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 12)),
                ]),
              ),
            const SizedBox(height: 4),
            const Text(
                'Fixed config prices only (Hard Rule 40) — repricing is a '
                'migration, not a console action.',
                style:
                    TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
          ]),
        ],
      ),
    );
  }

  Widget _settingSwitch(
      Map<String, dynamic> settings, String key, String label,
      {bool danger = false}) {
    final value = settings[key] == true;
    return SwitchListTile(
      value: value,
      dense: true,
      contentPadding: EdgeInsets.zero,
      activeTrackColor: danger ? AppTheme.danger : AppTheme.primary,
      title: Text(label,
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
      onChanged: (next) => _confirmToggle(
        key,
        next,
        '${next ? 'Enable' : 'Disable'} "$label"?',
        danger && next
            ? 'This opens a REAL-MONEY lane. KYC gates and the provenance '
                'lock stay enforced, but make sure this is the founder call.'
            : 'Takes effect immediately for every user.',
      ),
    );
  }

  Future<void> _confirmToggle(
      String key, Object value, String title, String message) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text(title,
            style:
                const TextStyle(color: AppTheme.textPrimary, fontSize: 16)),
        content: Text(message,
            style:
                const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Confirm')),
        ],
      ),
    );
    if (confirmed == true) {
      await _act({'action': 'toggle_setting', 'key': key, 'value': value});
    }
  }

  Future<void> _confirmMysteryMode(String mode) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: Text('Set Mystery Box mode to ${mode.toUpperCase()}?',
            style:
                const TextStyle(color: AppTheme.textPrimary, fontSize: 16)),
        content: Text(
            mode == 'disabled'
                ? 'Submissions and awards both stop refusing-safe: nothing can '
                    'enter or leave the pool.'
                : mode == 'sim'
                    ? 'Opens pool submissions and box awards against SIMULATED '
                        'dollar balances. Payout rates are still placeholders.'
                    : 'LIVE moves real money to creators who submit cards. Only '
                        'flip this once the founder and the payment rail are ready.',
            style:
                const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(
                  backgroundColor:
                      mode == 'live' ? AppTheme.danger : AppTheme.primary),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Confirm')),
        ],
      ),
    );
    if (confirmed == true) {
      await _act({'action': 'set_mystery_mode', 'value': mode});
    }
  }

  // ── Market tab (iteration 2) ──────────────────────────────────────────────
  Widget _marketTab() {
    if (_listings.isEmpty) {
      return const Center(
          child: Text('No active listings',
              style: TextStyle(color: AppTheme.textSecondary)));
    }
    return RefreshIndicator(
      onRefresh: _refresh,
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: _listings.map((l) {
          final chit =
              (l['moment_chits'] as Map?)?.cast<String, dynamic>() ?? const {};
          return _card(children: [
            Row(children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: chit['card_art_url'] != null
                    ? Image.network(chit['card_art_url'].toString(),
                        width: 40,
                        height: 54,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => const SizedBox(
                            width: 40,
                            height: 54,
                            child: Icon(Icons.image_outlined,
                                size: 18, color: AppTheme.textSecondary)))
                    : const SizedBox(
                        width: 40,
                        height: 54,
                        child: Icon(Icons.auto_awesome,
                            size: 18, color: AppTheme.textSecondary)),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text((chit['name'] ?? 'BattleChit').toString(),
                          style: const TextStyle(
                              color: AppTheme.textPrimary,
                              fontWeight: FontWeight.w700)),
                      const SizedBox(height: 2),
                      _meta('${l['tier_snapshot']}-tier · '
                          '${l['price_snapshot']} 🪙 · '
                          'seller ${l['seller_name']}'),
                      _meta('listed ${l['created_at']}'),
                    ]),
              ),
            ]),
            const SizedBox(height: 10),
            OutlinedButton.icon(
              style:
                  OutlinedButton.styleFrom(foregroundColor: AppTheme.danger),
              onPressed: () => _confirmDelist(l),
              icon: const Icon(Icons.remove_shopping_cart_outlined, size: 16),
              label: const Text('Delist (returns the card to the seller)'),
            ),
          ]);
        }).toList(),
      ),
    );
  }

  Future<void> _confirmDelist(Map<String, dynamic> l) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Delist this card?',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 16)),
        content: const Text(
            'The escrowed copy returns to the seller and the listing closes. '
            'Nothing is confiscated — use the review queue for content '
            'problems with the card itself.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Delist')),
        ],
      ),
    );
    if (confirmed == true) {
      await _act({'action': 'admin_delist', 'listing_id': l['id']});
    }
  }
}
