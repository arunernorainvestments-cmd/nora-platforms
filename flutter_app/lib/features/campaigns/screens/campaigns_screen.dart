import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:web/web.dart' as web;
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/n_back_button.dart';
import '../../auth/providers/auth_provider.dart';
import '../../collection/providers/collections_providers.dart';
import '../../mint/services/trim_interop.dart';
import '../../mint/widgets/clip_trimmer.dart';
import '../providers/campaign_providers.dart';

/// `/campaigns` — the Clip Campaigns board (Collections spec N7, §1.6).
///
/// Market Makers post clip bounties with the budget escrowed up front; clippers
/// submit trimmed clips; every submission is moderated before the Market Maker
/// can see it. A rejected clip is invisible here because RLS never returns it —
/// this screen has no "hide rejected" logic to get wrong.
class CampaignsScreen extends ConsumerWidget {
  const CampaignsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final open = ref.watch(openCampaignsProvider);
    final mine = ref.watch(myCampaignsProvider);
    final status = ref.watch(collectionMinterStatusProvider);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: const NBackButton(fallback: '/'),
        backgroundColor: AppTheme.background,
        title: const Text('Clip Campaigns'),
      ),
      floatingActionButton: status.maybeWhen(
        data: (s) => s.eligible
            ? FloatingActionButton.extended(
                backgroundColor: AppTheme.primary,
                onPressed: () => _createDialog(context, ref),
                icon: const Icon(Icons.add),
                label: const Text('Post a campaign'),
              )
            : null,
        orElse: () => null,
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(openCampaignsProvider);
          ref.invalidate(myCampaignsProvider);
          await ref.read(openCampaignsProvider.future);
        },
        child: ListView(padding: const EdgeInsets.all(16), children: [
          const Text(
            'Market Makers pay for clips they want. Submit a clip, and if it is '
            'accepted you get paid. Every clip is reviewed by platform '
            'moderation before the Market Maker sees it.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 20),
          mine.maybeWhen(
            data: (list) => list.isEmpty
                ? const SizedBox.shrink()
                : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    const Text('Your campaigns',
                        style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    for (final c in list) _CampaignTile(campaign: c, mine: true),
                    const SizedBox(height: 20),
                  ]),
            orElse: () => const SizedBox.shrink(),
          ),
          const Text('Open bounties',
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          open.when(
            loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 32),
                child: Center(child: CircularProgressIndicator())),
            error: (e, _) => Text('Could not load: $e',
                style: const TextStyle(color: AppTheme.danger)),
            data: (list) => list.isEmpty
                ? const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Text('No open campaigns right now.',
                        style: TextStyle(
                            color: AppTheme.textSecondary, fontSize: 13)),
                  )
                : Column(
                    children: [for (final c in list) _CampaignTile(campaign: c)],
                  ),
          ),
        ]),
      ),
    );
  }

  Future<void> _createDialog(BuildContext context, WidgetRef ref) async {
    final titleCtl = TextEditingController();
    final briefCtl = TextEditingController();
    final payoutCtl = TextEditingController(text: '5.00');
    final maxCtl = TextEditingController(text: '5');
    var days = 14;

    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) {
          final payout =
              ((double.tryParse(payoutCtl.text.trim()) ?? 0) * 100).round();
          final maxN = int.tryParse(maxCtl.text.trim()) ?? 0;
          final budget = payout * maxN;
          return AlertDialog(
            backgroundColor: AppTheme.surface,
            title: const Text('Post a clip campaign',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 17)),
            content: SingleChildScrollView(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                TextField(
                  controller: titleCtl,
                  maxLength: 120,
                  style: const TextStyle(color: AppTheme.textPrimary),
                  decoration: const InputDecoration(labelText: 'Title'),
                ),
                TextField(
                  controller: briefCtl,
                  maxLines: 3,
                  maxLength: 4000,
                  style: const TextStyle(color: AppTheme.textPrimary),
                  decoration: const InputDecoration(
                      labelText: 'What clips do you want?'),
                ),
                Row(children: [
                  Expanded(
                    child: TextField(
                      controller: payoutCtl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
                      ],
                      onChanged: (_) => setState(() {}),
                      style: const TextStyle(color: AppTheme.textPrimary),
                      decoration: const InputDecoration(
                          labelText: 'Per clip', prefixText: '\$'),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: TextField(
                      controller: maxCtl,
                      keyboardType: TextInputType.number,
                      inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                      onChanged: (_) => setState(() {}),
                      style: const TextStyle(color: AppTheme.textPrimary),
                      decoration:
                          const InputDecoration(labelText: 'Max clips'),
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text('Deadline: $days days',
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 12)),
                ),
                Slider(
                  value: days.toDouble(),
                  min: 1,
                  max: 90,
                  divisions: 89,
                  label: '$days days',
                  onChanged: (v) => setState(() => days = v.round()),
                ),
                const Divider(color: AppTheme.cardBorder),
                Text(
                  budget > 0
                      ? 'Budget \$${(budget / 100).toStringAsFixed(2)} is held in '
                          'escrow when you post. Unspent budget is refunded if you '
                          'cancel or the deadline passes.'
                      : 'Set a per-clip amount and a maximum.',
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12.5),
                ),
              ]),
            ),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(ctx, false),
                  child: const Text('Cancel')),
              FilledButton(
                onPressed: () async {
                  if (titleCtl.text.trim().isEmpty ||
                      briefCtl.text.trim().isEmpty ||
                      payout <= 0 ||
                      maxN < 1) {
                    return;
                  }
                  try {
                    await CampaignService.create(
                      title: titleCtl.text.trim(),
                      brief: briefCtl.text.trim(),
                      payoutPerClipCents: payout,
                      maxAccepted: maxN,
                      deadline: DateTime.now().add(Duration(days: days)),
                    );
                    if (ctx.mounted) Navigator.pop(ctx, true);
                  } catch (e) {
                    if (ctx.mounted) {
                      ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                          content: Text(CampaignService.errorMessage(e)),
                          backgroundColor: AppTheme.danger));
                    }
                  }
                },
                child: const Text('Post & escrow'),
              ),
            ],
          );
        },
      ),
    );
    if (created == true) {
      ref.invalidate(myCampaignsProvider);
      ref.invalidate(openCampaignsProvider);
    }
  }
}

class _CampaignTile extends StatelessWidget {
  const _CampaignTile({required this.campaign, this.mine = false});
  final ClipCampaign campaign;
  final bool mine;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.go('/campaigns/${campaign.id}'),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(campaign.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  '${campaign.payoutLabel} per clip · '
                  '${campaign.slotsLeft} of ${campaign.maxAccepted} left'
                  '${mine ? ' · ${campaign.status}' : ''}',
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: AppTheme.textSecondary),
        ]),
      ),
    );
  }
}

/// `/campaigns/:id` — brief + the two sides of the loop: a clipper submits, the
/// Market Maker reviews what moderation has cleared and accepts.
class CampaignDetailScreen extends ConsumerWidget {
  const CampaignDetailScreen({super.key, required this.campaignId});
  final String campaignId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final campaign = ref.watch(campaignProvider(campaignId));
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: const NBackButton(fallback: '/campaigns'),
        backgroundColor: AppTheme.background,
        title: const Text('Campaign'),
      ),
      body: campaign.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
            child: Text('Could not load: $e',
                style: const TextStyle(color: AppTheme.danger))),
        data: (c) => c == null
            ? const Center(
                child: Text('Campaign not found',
                    style: TextStyle(color: AppTheme.textSecondary)))
            : _body(context, ref, c),
      ),
    );
  }

  Widget _body(BuildContext context, WidgetRef ref, ClipCampaign c) {
    final myId = ref.watch(currentUserProvider)?.id;
    final isOwner = myId != null && myId == c.marketMakerUserId;
    final subs = ref.watch(campaignSubmissionsProvider(c.id));

    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(c.title,
          style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w800)),
      const SizedBox(height: 8),
      Text(c.brief,
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13.5)),
      const SizedBox(height: 14),
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Row(children: [
          Expanded(
            child: Text(
              '${c.payoutLabel} per accepted clip · ${c.slotsLeft} of '
              '${c.maxAccepted} slots left · closes '
              '${_dayLabel(c.deadline)}',
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 12.5),
            ),
          ),
        ]),
      ),
      if (c.mintEligible) ...[
        const SizedBox(height: 8),
        const Text(
          'Clips for this campaign are cut from the Market Maker\'s own verified '
          'post, so an accepted clip can also feed a card mint.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
        ),
      ],
      const SizedBox(height: 20),
      if (isOwner)
        _ownerSide(context, ref, c, subs)
      else
        _clipperSide(context, ref, c, subs),
    ]);
  }

  Widget _ownerSide(BuildContext context, WidgetRef ref, ClipCampaign c,
      AsyncValue<List<ClipSubmission>> subs) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const Text('Clips cleared by moderation',
          style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      const Text(
        'You only ever see clips that passed platform moderation.',
        style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
      ),
      const SizedBox(height: 10),
      subs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Text('Could not load: $e',
            style: const TextStyle(color: AppTheme.danger)),
        data: (list) => list.isEmpty
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 24),
                child: Text('No cleared clips yet.',
                    style:
                        TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
              )
            : Column(
                children: [
                  for (final s in list) _SubmissionRow(submission: s, owner: true),
                ],
              ),
      ),
      const SizedBox(height: 20),
      if (c.status == 'open' || c.status == 'reviewing')
        OutlinedButton.icon(
          onPressed: () => _cancel(context, ref, c),
          icon: const Icon(Icons.cancel_outlined, size: 18),
          label: Text(
              'Cancel & refund \$${(c.escrowRemainingCents / 100).toStringAsFixed(2)}'),
        ),
    ]);
  }

  Widget _clipperSide(BuildContext context, WidgetRef ref, ClipCampaign c,
      AsyncValue<List<ClipSubmission>> subs) {
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (c.isOpen)
        SizedBox(
          width: double.infinity,
          child: FilledButton.icon(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
            onPressed: () => context.go('/campaigns/${c.id}/submit'),
            icon: const Icon(Icons.video_call_outlined),
            label: const Text('Submit a clip'),
          ),
        )
      else
        const Text('This campaign is closed to new clips.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
      const SizedBox(height: 20),
      const Text('Your submissions',
          style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      subs.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Text('Could not load: $e',
            style: const TextStyle(color: AppTheme.danger)),
        data: (list) => list.isEmpty
            ? const Text('Nothing submitted yet.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 13))
            : Column(
                children: [
                  for (final s in list) _SubmissionRow(submission: s),
                ],
              ),
      ),
    ]);
  }

  Future<void> _cancel(
      BuildContext context, WidgetRef ref, ClipCampaign c) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Cancel campaign?',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 17)),
        content: const Text(
          'Remaining escrow is refunded to you and pending clips are closed out. '
          'Clips you already paid for are unaffected.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep it open')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Cancel campaign')),
        ],
      ),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final refunded = await CampaignService.cancel(c.id);
      messenger.showSnackBar(SnackBar(
          content: Text(
              'Campaign cancelled — \$${(refunded / 100).toStringAsFixed(2)} refunded.'),
          backgroundColor: AppTheme.surface));
      ref.invalidate(campaignProvider(c.id));
      ref.invalidate(myCampaignsProvider);
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(CampaignService.errorMessage(e)),
          backgroundColor: AppTheme.danger));
    }
  }

  static String _dayLabel(DateTime d) {
    final days = d.difference(DateTime.now()).inDays;
    if (days < 0) return 'closed';
    if (days == 0) return 'today';
    return 'in $days day${days == 1 ? '' : 's'}';
  }
}

class _SubmissionRow extends ConsumerStatefulWidget {
  const _SubmissionRow({required this.submission, this.owner = false});
  final ClipSubmission submission;
  final bool owner;

  @override
  ConsumerState<_SubmissionRow> createState() => _SubmissionRowState();
}

class _SubmissionRowState extends ConsumerState<_SubmissionRow> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final s = widget.submission;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Row(children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(_statusLabel(s.status),
                  style: TextStyle(
                      color: s.isPaid ? AppTheme.success : AppTheme.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w600)),
              if (s.note != null && s.note!.trim().isNotEmpty) ...[
                const SizedBox(height: 3),
                Text(s.note!,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 12)),
              ],
            ],
          ),
        ),
        if (widget.owner) ...[
          TextButton(
            onPressed: _busy ? null : _preview,
            child: const Text('Watch'),
          ),
          if (s.status == 'approved')
            FilledButton(
              onPressed: _busy ? null : _accept,
              child: _busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Text('Accept & pay'),
            ),
        ],
      ]),
    );
  }

  static String _statusLabel(String s) => switch (s) {
        'in_moderation' => 'In moderation',
        'submitted' => 'Submitted',
        'approved' => 'Cleared moderation',
        'accepted' => 'Accepted',
        'paid' => 'Accepted · paid',
        'rejected' => 'Not accepted',
        _ => s,
      };

  Future<void> _preview() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final url = await CampaignService.reviewUrl(widget.submission.clipPath);
      web.window.open(url, '_blank');
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(CampaignService.errorMessage(e)),
          backgroundColor: AppTheme.danger));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _accept() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await CampaignService.accept(widget.submission.id);
      messenger.showSnackBar(const SnackBar(
          content: Text('Clip accepted — the clipper has been paid.'),
          backgroundColor: AppTheme.surface));
      ref.invalidate(campaignSubmissionsProvider(widget.submission.campaignId));
      ref.invalidate(campaignProvider(widget.submission.campaignId));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(CampaignService.errorMessage(e)),
          backgroundColor: AppTheme.danger));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

/// `/campaigns/:id/submit` — pick a video, trim it to 1–15s in the browser, and
/// submit. The upload goes to the private clip-staging bucket under the
/// clipper's own prefix; `clip-submit` then moderates it before the Market Maker
/// can ever see it. Reuses the mint trimmer verbatim (spec N7: "the existing
/// device-clip path").
class CampaignSubmitScreen extends ConsumerStatefulWidget {
  const CampaignSubmitScreen({super.key, required this.campaignId});
  final String campaignId;

  @override
  ConsumerState<CampaignSubmitScreen> createState() =>
      _CampaignSubmitScreenState();
}

class _CampaignSubmitScreenState extends ConsumerState<CampaignSubmitScreen> {
  String? _objectUrl;
  String? _fileName;
  ClipProbe? _probe;
  List<String> _filmstrip = const [];
  int _startMs = 0;
  int _endMs = 0;
  bool _busy = false;
  double _progress = 0;
  String? _error;
  String? _result;
  final _noteCtl = TextEditingController();

  @override
  void dispose() {
    _revokeObjectUrl();
    _noteCtl.dispose();
    super.dispose();
  }

  void _revokeObjectUrl() {
    final u = _objectUrl;
    if (u != null) web.URL.revokeObjectURL(u);
    _objectUrl = null;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: NBackButton(fallback: '/campaigns/${widget.campaignId}'),
        backgroundColor: AppTheme.background,
        title: const Text('Submit a clip'),
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text(
          'Pick a video and trim the moment you want to submit (1–15 seconds). '
          'Every clip is checked by platform moderation before the Market Maker '
          'sees it.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 16),
        if (_result != null) ...[
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: AppTheme.cardBorder),
            ),
            child: Text(_result!,
                style: const TextStyle(
                    color: AppTheme.textPrimary, fontSize: 13)),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () => context.go('/campaigns/${widget.campaignId}'),
            child: const Text('Back to the campaign'),
          ),
        ] else ...[
          OutlinedButton.icon(
            onPressed: _busy ? null : _pickFile,
            icon: const Icon(Icons.upload_file, size: 18),
            label: Text(_fileName ?? 'Choose a video'),
          ),
          if (_probe != null && _objectUrl != null) ...[
            const SizedBox(height: 16),
            ClipTrimmer(
              objectUrl: _objectUrl!,
              durationMs: _probe!.durationMs,
              aspectRatio: _probe!.width / _probe!.height,
              filmstrip: _filmstrip,
              onSelectionChanged: (s, e) {
                _startMs = s;
                _endMs = e;
              },
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _noteCtl,
              maxLength: 500,
              maxLines: 2,
              style: const TextStyle(color: AppTheme.textPrimary),
              decoration: const InputDecoration(
                  labelText: 'Note to the Market Maker (optional)'),
            ),
            const SizedBox(height: 8),
            if (_busy) ...[
              LinearProgressIndicator(value: _progress > 0 ? _progress : null),
              const SizedBox(height: 8),
              const Text('Processing and uploading…',
                  style:
                      TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
            ] else
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  style:
                      FilledButton.styleFrom(backgroundColor: AppTheme.primary),
                  onPressed: _submit,
                  icon: const Icon(Icons.send),
                  label: const Text('Submit for review'),
                ),
              ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!,
                style: const TextStyle(color: AppTheme.danger, fontSize: 13)),
          ],
        ],
      ]),
    );
  }

  Future<void> _pickFile() async {
    final input = web.HTMLInputElement()
      ..type = 'file'
      ..accept = 'video/mp4,video/quicktime,video/*';
    input.click();
    await input.onChange.first;
    final file = input.files?.item(0);
    if (file == null) return;

    setState(() {
      _busy = true;
      _error = null;
      _filmstrip = const [];
      _probe = null;
    });
    _revokeObjectUrl();
    final objectUrl = web.URL.createObjectURL(file);
    try {
      final probe = await TrimEngine.probe(objectUrl);
      if (probe.durationMs < ClipTrimmer.minSelectionMs) {
        throw StateError('That video is under 1 second');
      }
      final filmstrip = await TrimEngine.filmstrip(objectUrl);
      if (!mounted) return;
      setState(() {
        _objectUrl = objectUrl;
        _fileName = file.name;
        _probe = probe;
        _filmstrip = filmstrip;
        _startMs = 0;
        _endMs = probe.durationMs.clamp(
            ClipTrimmer.minSelectionMs, ClipTrimmer.maxSelectionMs);
      });
      unawaited(TrimEngine.warmUp().catchError((_) {}));
    } catch (e) {
      web.URL.revokeObjectURL(objectUrl);
      if (mounted) {
        setState(() => _error = e is StateError
            ? e.message
            : "This browser can't read that video format — try an MP4/MOV export");
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    final url = _objectUrl;
    if (url == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _progress = 0;
    });
    try {
      final clip = await TrimEngine.process(
        objectUrl: url,
        startMs: _startMs,
        endMs: _endMs,
        keepAudio: true,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      final res = await CampaignService.submit(
        campaignId: widget.campaignId,
        clipBytes: clip.video,
        frames: clip.frames,
        note: _noteCtl.text,
        trimStartMs: _startMs,
        trimEndMs: _endMs,
      );
      if (!mounted) return;
      final status = res['status'] as String?;
      setState(() {
        _result = switch (status) {
          'approved' =>
            'Your clip passed moderation and is now with the Market Maker.',
          'rejected' =>
            'This clip did not pass content moderation and was not submitted.',
          _ =>
            'Your clip is queued for review and will be checked shortly.',
        };
      });
      ref.invalidate(campaignSubmissionsProvider(widget.campaignId));
    } catch (e) {
      if (mounted) {
        setState(() => _error = CampaignService.errorMessage(e));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}
