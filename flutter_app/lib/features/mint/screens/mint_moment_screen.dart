import 'dart:async';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:web/web.dart' as web;
import '../../../core/theme/app_theme.dart';
import '../services/mint_service.dart';
import '../services/trim_interop.dart';
import '../widgets/clip_trimmer.dart';

/// "Create Your BattleChit" — minting v2 §1 (Minting_Workflow.md).
///
/// Step 1  link an owned post (moment-ingest: OAuth ownership + source moderation).
/// Step 2  the platform APIs can't hand us the file, so the user uploads the clip
///         from their device and trims it to 1–15s in-browser (ffmpeg.wasm).
/// Step 3  trimmed mp4 + 4 sample frames upload to mint-staging; moment-clip-attach
///         re-moderates + similarity-checks, then the clip is staged for generation.
class MintMomentScreen extends StatefulWidget {
  const MintMomentScreen({super.key});

  @override
  State<MintMomentScreen> createState() => _MintMomentScreenState();
}

enum _Step { link, clip, processing, result }

class _MintMomentScreenState extends State<MintMomentScreen> {
  _Step _step = _Step.link;
  final _urlController = TextEditingController();
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

  @override
  void dispose() {
    _urlController.dispose();
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

  // ── Step 3: trim → upload → attach ────────────────────────────────────────
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
      setState(() {
        _attachResult = res;
        _step = _Step.result;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e is MintException ? e.message : 'Processing failed — $e';
        _step = _Step.clip;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        title: const Text('Create Your BattleChit'),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 560),
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: switch (_step) {
              _Step.link => _buildLinkStep(),
              _Step.clip => _buildClipStep(),
              _Step.processing => _buildProcessingStep(),
              _Step.result => _buildResultStep(),
            },
          ),
        ),
      ),
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
        'Paste a link to a TikTok, Instagram, or YouTube post you own. '
        'Your engagement on the post sets the card\'s tier.',
        style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
      ),
      const SizedBox(height: 16),
      TextField(
        controller: _urlController,
        style: const TextStyle(color: AppTheme.textPrimary),
        decoration: const InputDecoration(
          hintText: 'https://www.tiktok.com/@you/video/…',
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
        if (tier != null)
          Container(
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
          ),
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
          _progress == null
              ? _phase
              : '$_phase ${(_progress! * 100).round()}%',
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

  Widget _buildResultStep() {
    final status = _attachResult?['clip_status']?.toString();
    final (icon, color, title, detail) = switch (status) {
      'attached' => (
          Icons.check_circle,
          AppTheme.success,
          'Clip staged!',
          'Your moment passed safety checks. The generation pipeline takes it '
              'from here — your BattleChit cutscene will appear in your collection.',
        ),
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
          style:
              const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
      const SizedBox(height: 20),
      FilledButton(
        onPressed: () => context.go('/battle'),
        child: const Text('Back to the Arena'),
      ),
      TextButton(
        onPressed: () {
          setState(() {
            _step = _Step.link;
            _moment = null;
            _attachResult = null;
            _fileName = null;
            _probe = null;
            _filmstrip = const [];
            _urlController.clear();
            _revokeObjectUrl();
          });
        },
        child: const Text('Mint another moment',
            style: TextStyle(color: AppTheme.secondary)),
      ),
    ]);
  }
}
