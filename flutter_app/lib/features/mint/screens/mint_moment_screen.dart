import 'dart:async';
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:web/web.dart' as web;
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/card_face.dart';
import '../../market/providers/market_providers.dart';
import '../services/mint_service.dart';
import '../services/trim_interop.dart';
import '../widgets/clip_trimmer.dart';
import '../../../core/widgets/n_back_button.dart';

/// "Create Your BattleChit" — minting v2 §1 (Minting_Workflow.md) end to end.
///
/// Step 1  link an owned post (moment-ingest: OAuth ownership + source moderation).
/// Step 2  the platform APIs can't hand us the file, so the user uploads the clip
///         from their device and trims it to 1–15s in-browser (ffmpeg.wasm).
/// Step 3  trimmed mp4 + 4 sample frames upload to mint-staging; moment-clip-attach
///         re-moderates + similarity-checks, then the clip is staged.
/// Step 4  review: moment-classify recommends family (locked, content-derived) + a
///         name + subject; the user confirms, then cinematic-mint generates the card.
/// Step 5  preview: the generated card art + cutscene; finalizing adds it to the
///         collection (web preview stands in for the practice-battle gate for now).
class MintMomentScreen extends StatefulWidget {
  const MintMomentScreen({super.key});

  @override
  State<MintMomentScreen> createState() => _MintMomentScreenState();
}

enum _Step { link, clip, processing, review, generating, preview, done }

class _MintMomentScreenState extends State<MintMomentScreen> {
  _Step _step = _Step.link;
  final _urlController = TextEditingController();
  final _nameController = TextEditingController();
  bool _busy = false;
  String? _error;

  // Step-1 output.
  Map<String, dynamic>? _moment;

  // Step-2 state.
  String? _objectUrl;
  String? _fileName;
  ClipProbe? _probe;
  List<String> _filmstrip = const [];
  int _startMs = 0;
  int _endMs = 0;
  bool _keepAudio = true;

  // Step-3 state.
  String _phase = '';
  double? _progress;
  Map<String, dynamic>? _attachResult;

  // Step-4 state.
  Map<String, dynamic>? _classify;
  String _chitType = 'creature';
  String? _autoFamily; // the automatic recommendation, kept for the selector label
  String _familySelection = 'auto'; // 'auto' or one of _families
  bool _familyBusy = false;

  static const _families = [
    'athlete', 'musician', 'artist', 'scientist', 'comedian',
    'influencer', 'politician', 'business', 'gamer', 'actor',
  ];

  // Step-5 state.
  Map<String, dynamic>? _mint;
  Map<String, dynamic>? _chitRow;

  @override
  void dispose() {
    _urlController.dispose();
    _nameController.dispose();
    _revokeObjectUrl();
    super.dispose();
  }

  void _revokeObjectUrl() {
    if (_objectUrl != null) web.URL.revokeObjectURL(_objectUrl!);
    _objectUrl = null;
  }

  // ── Step 1: link the owned post ───────────────────────────────────────────
  Future<void> _ingest() async {
    final url = _urlController.text.trim();
    if (url.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final res = await MintService.ingest(url);
      if (!mounted) return;
      if (res['status'] != 'approved') {
        setState(() => _error =
            res['detail']?.toString() ?? 'This post cannot be minted');
        return;
      }
      setState(() {
        _moment = res;
        _step = _Step.clip;
      });
    } on MintException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Step 2: pick + trim the device clip ───────────────────────────────────
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
      });
      // Warm the 31MB wasm download while the user is busy trimming.
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

  // ── Step 3: trim → upload → attach → (on clean attach) classify ───────────
  Future<void> _processAndUpload() async {
    final objectUrl = _objectUrl;
    final momentId = _moment?['moment_id'] as String?;
    if (objectUrl == null || momentId == null) return;
    setState(() {
      _step = _Step.processing;
      _error = null;
      _phase = 'Loading the video engine (one-time, ~30MB)…';
      _progress = null;
    });
    try {
      await TrimEngine.warmUp();
      if (!mounted) return;
      setState(() => _phase = 'Trimming your clip…');
      final clip = await TrimEngine.process(
        objectUrl: objectUrl,
        startMs: _startMs,
        endMs: _endMs,
        keepAudio: _keepAudio,
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (!mounted) return;
      setState(() {
        _phase = 'Uploading…';
        _progress = null;
      });
      await MintService.uploadStaged(
        momentId: momentId,
        video: clip.video,
        frames: clip.frames,
      );
      if (!mounted) return;
      setState(() => _phase = 'Running safety checks…');
      final res = await MintService.attachClip(
        momentId: momentId,
        trimStartMs: _startMs,
        trimEndMs: _endMs,
        keepAudio: _keepAudio,
      );
      if (!mounted) return;
      _attachResult = res;
      if (res['clip_status'] == 'attached') {
        await _startReview(momentId); // straight into recommend/classify
      } else {
        // similarity_flagged / rejected are terminal, handled by the result card.
        setState(() => _step = _Step.done);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is MintException ? e.message : 'Processing failed — $e';
        _step = _Step.clip;
      });
    }
  }

  // ── Step 4: classify (recommend) then let the user confirm ────────────────
  Future<void> _startReview(String momentId) async {
    setState(() {
      _step = _Step.processing;
      _phase = 'Reading your moment…';
      _progress = null;
    });
    try {
      final c = await MintService.classify(momentId);
      if (!mounted) return;
      _nameController.text = (c['suggested_name'] ?? '').toString();
      setState(() {
        _classify = c;
        _chitType = (c['chit_type'] ?? 'creature').toString();
        _autoFamily = c['family']?.toString();
        _familySelection = 'auto';
        _step = _Step.review;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is MintException ? e.message : 'Could not read your moment — $e';
        _step = _Step.clip;
      });
    }
  }

  /// Family selector: 'auto' re-runs the content classification; a named family
  /// re-calls moment-classify with family_override so the effect is re-selected
  /// server-side from that family's authored library (style changes, power doesn't).
  Future<void> _setFamily(String selection, {bool force = false}) async {
    final momentId = _moment?['moment_id'] as String?;
    final c = _classify;
    if (momentId == null || c == null || (!force && selection == _familySelection)) {
      return;
    }
    setState(() {
      _familyBusy = true;
      _error = null;
    });
    try {
      final res = await MintService.classify(
        momentId,
        familyOverride: selection == 'auto' ? null : selection,
        subjectDesc: c['subject_desc']?.toString(),
        chitType: _chitType,
      );
      if (!mounted) return;
      setState(() {
        _familySelection = selection;
        c['family'] = res['family'];
        c['effect_template_id'] = res['effect_template_id'];
        c['effect_timing'] = res['effect_timing'];
        c['effect_name'] = res['effect_name'];
        if (selection == 'auto') _autoFamily = res['family']?.toString();
      });
    } catch (e) {
      if (mounted) {
        setState(() =>
            _error = e is MintException ? e.message : 'Could not set family — $e');
      }
    } finally {
      if (mounted) setState(() => _familyBusy = false);
    }
  }

  Future<void> _generate({String? swapOfChitId, bool swapConfirm = false}) async {
    final momentId = _moment?['moment_id'] as String?;
    final c = _classify;
    if (momentId == null || c == null) return;
    setState(() {
      _step = _Step.generating;
      _error = null;
    });
    try {
      final res = await MintService.generate(
        momentId: momentId,
        family: c['family'].toString(),
        chitType: _chitType,
        subjectDesc: c['subject_desc'].toString(),
        name: _nameController.text,
        swapOfChitId: swapOfChitId,
        swapConfirm: swapConfirm,
      );
      if (!mounted) return;
      if (res['error'] == 'self_mint_slot_occupied') {
        setState(() => _step = _Step.review);
        await _confirmSwap(res['occupied_chit_id']?.toString());
        return;
      }
      // Held for post-generation safety review (Hard Rule 39): the cutscene was
      // generated but a moderation verdict is still needed — terminal for now.
      if (res['status'] == 'pending_moderation') {
        setState(() {
          _mint = res;
          _step = _Step.done;
        });
        return;
      }
      // Pull the full chit row (tier-derived stats) so the preview shows a
      // complete card face — best-effort; the preview still renders without it.
      Map<String, dynamic>? chit;
      final chitId = res['chit_id'] as String?;
      if (chitId != null) {
        try {
          chit = await MintService.fetchChit(chitId);
        } catch (_) {/* preview falls back to review data */}
      }
      if (!mounted) return;
      setState(() {
        _mint = res;
        _chitRow = chit;
        _step = _Step.preview;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is MintException ? e.message : 'Generation failed — $e';
        _step = _Step.review;
      });
    }
  }

  Future<void> _confirmSwap(String? occupiedChitId) async {
    if (occupiedChitId == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Replace your current BattleChit?',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text(
          'You can have one self-minted card at a time. Minting this one permanently '
          'deletes your current card and its cutscene. This can\'t be undone.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep current'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Replace it'),
          ),
        ],
      ),
    );
    if (ok == true) {
      await _generate(swapOfChitId: occupiedChitId, swapConfirm: true);
    }
  }

  // ── Step 5: finalize the previewed chit into the collection ───────────────
  Future<void> _finalize() async {
    final chitId = _mint?['chit_id'] as String?;
    if (chitId == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await MintService.recordPreview(chitId);
      await MintService.finalizePreview(chitId);
      if (!mounted) return;
      setState(() => _step = _Step.done);
    } catch (e) {
      if (mounted) setState(() => _error = 'Could not finalize — $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  // ── Done: list the freshly minted chit on the marketplace (M3). Server
  // validates everything (ownership, finalized, allowance — Hard Rule 40).
  Future<void> _sellFreshMint() async {
    final chitId = _mint?['chit_id'] as String?;
    if (chitId == null) return;
    final tier = (_chitRow?['tier'] ?? '').toString();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('List it for sale?',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          'Your card will be listed on the Chit Market at its fixed '
          '${tier.isEmpty ? 'tier' : 'Tier $tier'} price. While listed it '
          'leaves your collection (held in escrow) and can\'t battle or '
          'ascend. You can delist anytime before it sells.',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Not now'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('List it'),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await MarketService.listChit(chitId);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Listed on the Chit Market.'),
          backgroundColor: AppTheme.surface));
      context.go('/market');
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(MarketService.errorMessage(e)),
          backgroundColor: AppTheme.danger));
    }
  }

  // ── Step 5: cancel — discard the pending chit (Hard Rule 39 blocks going back
  // through Safety/Review to re-generate, but backing out entirely is always allowed).
  Future<void> _cancelMint() async {
    final chitId = _mint?['chit_id'] as String?;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Discard this card?',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text(
          'This cancels the mint and permanently deletes the generated card and its '
          'cutscene. Your original moment stays linked, so you can mint it again. '
          'This can\'t be undone.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Keep editing'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Discard'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    // No chit id (shouldn't happen at Preview) → just reset the wizard locally.
    if (chitId == null) { _reset(); return; }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await MintService.cancelMint(chitId);
      if (!mounted) return;
      _reset();
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e is MintException ? e.message : 'Could not discard — $e';
          _busy = false;
        });
      }
    }
  }

  void _reset() {
    setState(() {
      _step = _Step.link;
      _moment = null;
      _attachResult = null;
      _classify = null;
      _mint = null;
      _chitRow = null;
      _fileName = null;
      _probe = null;
      _filmstrip = const [];
      _chitType = 'creature';
      _autoFamily = null;
      _familySelection = 'auto';
      _familyBusy = false;
      _urlController.clear();
      _nameController.clear();
      _revokeObjectUrl();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: const NBackButton(fallback: '/battle'),
        backgroundColor: AppTheme.background,
        title: const Text('Create Your BattleChit'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _stepper(),
                const SizedBox(height: 20),
                switch (_step) {
                  _Step.link => _buildLinkStep(),
                  _Step.clip => _buildClipStep(),
                  _Step.processing => _buildProcessingStep(),
                  _Step.review => _buildReviewStep(),
                  _Step.generating => _buildGeneratingStep(),
                  _Step.preview => _buildPreviewStep(),
                  _Step.done => _buildDoneStep(),
                },
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── walkthrough: the whole journey, always visible ────────────────────────
  static const _stepLabels = ['Verify', 'Upload', 'Safety', 'Review', 'Preview'];

  int get _activeStepIndex => switch (_step) {
        _Step.link => 0,
        _Step.clip => 1,
        _Step.processing => 2,
        _Step.review => 3,
        _Step.generating => 4,
        _Step.preview => 4,
        _Step.done => 4,
      };

  Widget _stepper() {
    final active = _activeStepIndex;
    return Row(
      children: List.generate(_stepLabels.length, (i) {
        final done = i < active || _step == _Step.done;
        final current = i == active && _step != _Step.done;
        final color = done
            ? AppTheme.success
            : current
                ? AppTheme.primary
                : AppTheme.cardBorder;
        return Expanded(
          child: Column(
            children: [
              Row(children: [
                Expanded(
                    child: Container(
                        height: 2,
                        color: i == 0 ? Colors.transparent : color)),
                CircleAvatar(
                  radius: 12,
                  backgroundColor: color,
                  child: done
                      ? const Icon(Icons.check, size: 14, color: Colors.white)
                      : Text('${i + 1}',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: current
                                  ? Colors.white
                                  : AppTheme.textSecondary)),
                ),
                Expanded(
                    child: Container(
                        height: 2,
                        color: i == _stepLabels.length - 1
                            ? Colors.transparent
                            : (i < active ? AppTheme.success : AppTheme.cardBorder))),
              ]),
              const SizedBox(height: 4),
              Text(_stepLabels[i],
                  style: TextStyle(
                      fontSize: 10,
                      color: current ? AppTheme.textPrimary : AppTheme.textSecondary)),
            ],
          ),
        );
      }),
    );
  }

  Widget _card({required List<Widget> children}) => Container(
        padding: const EdgeInsets.all(20),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: children,
        ),
      );

  Widget _errorBanner() => _error == null
      ? const SizedBox.shrink()
      : Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(
            _error!,
            style: const TextStyle(color: AppTheme.danger, fontSize: 13),
          ),
        );

  Widget _buildLinkStep() {
    return _card(children: [
      const Text('1 · Pick your moment',
          style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      const Text(
        'Here\'s how it works: verify a post you own → upload & trim that clip → '
        'we run safety checks → review the card we recommend → preview it and add '
        'it to your collection. Takes about a minute.',
        style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
      ),
      const SizedBox(height: 16),
      const Text(
        'Paste a link to a TikTok, Instagram, or YouTube post you own. It has to be '
        'on an account you\'ve linked, and your engagement on it sets the card\'s tier.',
        style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _urlController,
        style: const TextStyle(color: AppTheme.textPrimary),
        decoration: const InputDecoration(
          hintText: 'https://www.youtube.com/watch?v=…',
          hintStyle: TextStyle(color: AppTheme.textSecondary),
        ),
        onSubmitted: (_) => _ingest(),
      ),
      const SizedBox(height: 8),
      TextButton(
        onPressed: () => context.go('/profile'),
        child: const Text('Manage linked accounts in Profile',
            style: TextStyle(color: AppTheme.secondary, fontSize: 12)),
      ),
      const SizedBox(height: 8),
      FilledButton(
        onPressed: _busy ? null : _ingest,
        child: _busy
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Text('Verify my post'),
      ),
      _errorBanner(),
    ]);
  }

  Widget _buildClipStep() {
    final handle = _moment?['creator_handle'] ?? '';
    final tier = _moment?['projected_tier'];
    return _card(children: [
      Row(children: [
        const Icon(Icons.verified, color: AppTheme.success, size: 18),
        const SizedBox(width: 6),
        Expanded(
          child: Text('Post verified — $handle',
              style: const TextStyle(
                  color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
        ),
        if (tier != null) _tierChip(tier),
      ]),
      const SizedBox(height: 16),
      const Text('2 · Upload that clip from your device',
          style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700)),
      const SizedBox(height: 8),
      const Text(
        'Social platforms don\'t let us download your video, so grab it from '
        'your camera roll. Then trim the exact 1–15 seconds that IS the moment.',
        style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
      ),
      const SizedBox(height: 16),
      OutlinedButton.icon(
        onPressed: _busy ? null : _pickFile,
        icon: const Icon(Icons.video_file_outlined),
        label: Text(_fileName ?? 'Choose a video'),
      ),
      if (_objectUrl != null && _probe != null) ...[
        const SizedBox(height: 16),
        ClipTrimmer(
          key: ValueKey(_objectUrl),
          objectUrl: _objectUrl!,
          durationMs: _probe!.durationMs,
          aspectRatio: _probe!.height == 0 ? 1 : _probe!.width / _probe!.height,
          filmstrip: _filmstrip,
          onSelectionChanged: (s, e) {
            _startMs = s;
            _endMs = e;
          },
        ),
        SwitchListTile(
          value: _keepAudio,
          onChanged: (v) => setState(() => _keepAudio = v),
          title: const Text('Keep original audio',
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 14)),
          activeTrackColor: AppTheme.primary,
          contentPadding: EdgeInsets.zero,
        ),
        const SizedBox(height: 8),
        FilledButton.icon(
          onPressed: _busy ? null : _processAndUpload,
          icon: const Icon(Icons.auto_awesome),
          label: const Text('Trim & stage for minting'),
        ),
      ],
      _errorBanner(),
    ]);
  }

  Widget _buildProcessingStep() {
    return _card(children: [
      const SizedBox(height: 8),
      Center(
        child: SizedBox(
          width: 56,
          height: 56,
          child: CircularProgressIndicator(
            value: _progress,
            color: AppTheme.secondary,
            backgroundColor: AppTheme.surfaceLight,
          ),
        ),
      ),
      const SizedBox(height: 20),
      Center(
        child: Text(
          _progress == null ? _phase : '$_phase ${(_progress! * 100).round()}%',
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14),
        ),
      ),
      const SizedBox(height: 8),
      const Center(
        child: Text('Keep this tab open',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
      ),
      const SizedBox(height: 8),
    ]);
  }

  Widget _buildReviewStep() {
    final c = _classify ?? const {};
    final family = (c['family'] ?? '').toString();
    final tier = _moment?['projected_tier'];
    return _card(children: [
      Row(children: [
        const Expanded(
          child: Text('4 · Review your card',
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700)),
        ),
        if (tier != null) _tierChip(tier),
      ]),
      const SizedBox(height: 12),
      const Text('Family',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
      const SizedBox(height: 6),
      DropdownButtonFormField<String>(
        initialValue: _familySelection,
        dropdownColor: AppTheme.surfaceLight,
        style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14),
        decoration: InputDecoration(
          prefixIcon: _familyBusy
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2)),
                )
              : const Icon(Icons.category_outlined,
                  size: 18, color: AppTheme.secondary),
        ),
        items: [
          DropdownMenuItem(
            value: 'auto',
            child: Text(_autoFamily == null
                ? 'Automatic'
                : 'Automatic — ${_pretty(_autoFamily!)} (recommended)'),
          ),
          for (final f in _families)
            DropdownMenuItem(value: f, child: Text(_pretty(f))),
        ],
        onChanged: _familyBusy ? null : (v) => v == null ? null : _setFamily(v),
      ),
      const SizedBox(height: 4),
      Text(
        _familySelection == 'auto'
            ? 'Automatic reads your content to pick the family — it decides the '
                'card\'s effect style, never its power. Think it fits a different '
                'family? Pick it yourself above.'
            : 'You chose ${_pretty(family)}. The card\'s effect is re-drawn from the '
                '${_pretty(family)} playbook — its power still comes from your '
                'engagement tier.',
        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
      ),
      if ((c['effect_name'] ?? '').toString().isNotEmpty) ...[
        const SizedBox(height: 8),
        Row(children: [
          _lockedChip(Icons.bolt_outlined, 'Effect: ${c['effect_name']}'),
        ]),
      ],
      const SizedBox(height: 16),
      const Text('Card name',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
      const SizedBox(height: 6),
      TextField(
        controller: _nameController,
        maxLength: 40,
        style: const TextStyle(color: AppTheme.textPrimary),
        decoration: const InputDecoration(counterText: ''),
      ),
      const SizedBox(height: 12),
      const Text('Card type',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
      const SizedBox(height: 6),
      SegmentedButton<String>(
        segments: const [
          ButtonSegment(value: 'creature', label: Text('Creature')),
          ButtonSegment(value: 'spell_moment', label: Text('Spell')),
        ],
        selected: {_chitType},
        onSelectionChanged: _familyBusy
            ? null
            : (s) {
                setState(() => _chitType = s.first);
                // Spells draw from a narrower effect pool — re-select server-side.
                _setFamily(_familySelection, force: true);
              },
      ),
      const SizedBox(height: 16),
      Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.surfaceLight,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          '“${c['subject_desc'] ?? ''}”',
          style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 13,
              fontStyle: FontStyle.italic),
        ),
      ),
      const SizedBox(height: 16),
      FilledButton.icon(
        onPressed: _familyBusy ? null : _generate,
        icon: const Icon(Icons.movie_filter_outlined),
        label: const Text('Generate my BattleChit'),
      ),
      _errorBanner(),
    ]);
  }

  /// 'spell_moment' aside, families are single words — just capitalize.
  static String _pretty(String s) =>
      s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

  Widget _buildGeneratingStep() {
    return _card(children: [
      const SizedBox(height: 8),
      const Center(
        child: SizedBox(
          width: 56,
          height: 56,
          child: CircularProgressIndicator(color: AppTheme.secondary),
        ),
      ),
      const SizedBox(height: 20),
      const Center(
        child: Text('Generating your cutscene…',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 14)),
      ),
      const SizedBox(height: 8),
      const Center(
        child: Text('Rendering the card art and match-cut — this can take a moment.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
      ),
      const SizedBox(height: 8),
    ]);
  }

  /// sim mode returns placeholder media (a 1x1 png + a non-playable mp4 stub), so we
  /// don't try to render them as real art/video — we show an honest "coming when live"
  /// state. Real art + cutscene arrive when CINEMATIC_MODE=live (Segmind).
  bool get _mediaPlaceholder => _mint?['media_placeholder'] == true;

  Widget _buildPreviewStep() {
    final mp4 = _mint?['mp4_cutscene_url']?.toString();
    return _card(children: [
      const Text('5 · Preview & finalize',
          style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700)),
      const SizedBox(height: 4),
      const Text('Here\'s your card. Give it a look, then add it to your collection.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
      const SizedBox(height: 16),
      Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: _previewCardFace(),
        ),
      ),
      const SizedBox(height: 20),
      const Row(children: [
        Icon(Icons.movie_outlined, size: 16, color: AppTheme.textSecondary),
        SizedBox(width: 6),
        Text('Summon cutscene',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
      ]),
      const SizedBox(height: 8),
      if (_mediaPlaceholder)
        _mediaComingSoon('Your cutscene renders here once the cinematic engine is '
            'switched on. The card art + animation are generated from your clip at '
            'that point.')
      else if (mp4 != null)
        AspectRatio(aspectRatio: 16 / 9, child: _CutsceneVideo(url: mp4)),
      const SizedBox(height: 20),
      FilledButton.icon(
        onPressed: _busy ? null : _finalize,
        icon: _busy
            ? const SizedBox(
                width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.check_circle_outline),
        label: const Text('Looks good — add to my collection'),
      ),
      const SizedBox(height: 8),
      TextButton.icon(
        onPressed: _busy ? null : _cancelMint,
        icon: const Icon(Icons.close, size: 18, color: AppTheme.danger),
        label: const Text('Cancel & discard this card',
            style: TextStyle(color: AppTheme.danger)),
      ),
      _errorBanner(),
    ]);
  }

  /// The 16:9 "renders when live" placeholder used for the cutscene (and mirrored as
  /// the card-art caption) in sim mode.
  Widget _mediaComingSoon(String message) {
    return AspectRatio(
      aspectRatio: 16 / 9,
      child: Container(
        decoration: BoxDecoration(
          color: AppTheme.background,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.primary.withValues(alpha: 0.35)),
        ),
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const Icon(Icons.auto_awesome, color: AppTheme.primary, size: 28),
            const SizedBox(height: 10),
            Text(message,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 12, height: 1.35)),
          ],
        ),
      ),
    );
  }

  Widget _previewCardFace() {
    final c = _chitRow;
    return CardFace(
      name: (c?['name'] ?? _nameController.text).toString(),
      chitType: (c?['chit_type'] ?? _chitType).toString(),
      family: (c?['archetype_family'] ?? _classify?['family'] ?? '').toString(),
      tier: (c?['tier'] ?? _mint?['tier'] ?? '').toString(),
      auraCost: (c?['aura_cost'] as num?)?.toInt() ?? 0,
      atk: (c?['atk'] as num?)?.toInt(),
      hp: (c?['hp'] as num?)?.toInt(),
      keywords: (c?['keywords'] as List?)?.map((e) => e.toString()).toList() ?? const [],
      // In sim mode the stored art is a 1x1 placeholder — pass null so CardFace shows
      // its clean fallback glyph instead of a blank window.
      cardArtUrl: _mediaPlaceholder
          ? null
          : (c?['card_art_url'] ?? _mint?['card_art_url'])?.toString(),
      minterHandle: c?['original_minter_handle']?.toString(),
      sourcePlatform: c?['source_platform']?.toString(),
      rulesText: c?['rules_text']?.toString(),
      flavor: c?['flavor_text']?.toString(),
      serial: c?['card_serial']?.toString(),
    );
  }

  Widget _buildDoneStep() {
    // Terminal states: finalized chit, held-for-review generation, or a
    // flagged/rejected attach.
    final status = _attachResult?['clip_status']?.toString();
    final heldForReview = _mint?['status'] == 'pending_moderation';
    final finalized = _step == _Step.done && _mint != null && !heldForReview;
    final (icon, color, title, detail) = finalized
        ? (
            Icons.check_circle,
            AppTheme.success,
            'BattleChit minted!',
            'It\'s in your collection now. Preview it in a practice battle to lock '
                'it into your deck.',
          )
        : heldForReview
            ? (
                Icons.hourglass_top,
                AppTheme.secondary,
                'Held for safety review',
                'Your cutscene was generated and is getting a quick safety check '
                    'before the card is created. Check back soon — no need to '
                    'generate again.',
              )
            : switch (status) {
            'similarity_flagged' => (
                Icons.hourglass_top,
                AppTheme.secondary,
                'Staged — pending review',
                'The clip didn\'t visually match the post you linked, so a human will '
                    'take a quick look before generation runs.',
              ),
            _ => (
                Icons.cancel,
                AppTheme.danger,
                'Clip rejected',
                _attachResult?['detail']?.toString() ??
                    'This clip did not pass content moderation.',
              ),
          };
    return _card(children: [
      Icon(icon, color: color, size: 48),
      const SizedBox(height: 12),
      Center(
        child: Text(title,
            style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700)),
      ),
      const SizedBox(height: 8),
      Text(detail,
          textAlign: TextAlign.center,
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
      const SizedBox(height: 20),
      if (finalized) ...[
        FilledButton(
          onPressed: () => context.go('/collection'),
          child: const Text('View my collection'),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: _sellFreshMint,
          icon: const Icon(Icons.sell_outlined),
          label: const Text('Sell it on the Chit Market'),
        ),
      ] else
        FilledButton(
          onPressed: () => context.go('/battle'),
          child: const Text('Back to the Arena'),
        ),
      TextButton(
        onPressed: _reset,
        child: const Text('Mint another moment',
            style: TextStyle(color: AppTheme.secondary)),
      ),
    ]);
  }

  Widget _tierChip(Object tier) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: AppTheme.primary.withValues(alpha: 0.18),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text('Tier $tier',
            style: const TextStyle(
                color: AppTheme.primary,
                fontSize: 12,
                fontWeight: FontWeight.w700)),
      );

  Widget _lockedChip(IconData icon, String label) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: AppTheme.surfaceLight,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 14, color: AppTheme.secondary),
          const SizedBox(width: 6),
          Text(label,
              style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ]),
      );
}

/// Embeds the generated cutscene MP4 as an autoplaying, muted, looping HTML5
/// video (Flutter web has no native video widget without extra plugins).
class _CutsceneVideo extends StatelessWidget {
  const _CutsceneVideo({required this.url});
  final String url;

  @override
  Widget build(BuildContext context) {
    final viewType = 'cutscene-${url.hashCode}';
    // Registering the same viewType twice is a harmless no-op across rebuilds.
    ui_web.platformViewRegistry.registerViewFactory(viewType, (int _) {
      final video = web.HTMLVideoElement()
        ..src = url
        ..autoplay = true
        ..muted = true
        ..loop = true
        ..controls = true
        ..setAttribute('playsinline', 'true')
        ..style.width = '100%'
        ..style.height = '100%'
        ..style.borderRadius = '12px'
        ..style.objectFit = 'cover';
      return video;
    });
    return HtmlElementView(viewType: viewType);
  }
}
