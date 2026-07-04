import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;
import '../../../core/theme/app_theme.dart';

/// TikTok-style single-bar trimmer over the user's device clip (Minting_Workflow.md
/// §1B): an HTML <video> preview + a filmstrip with a dual-handle range selection.
/// Selection is clamped to 1–15s; the handle being dragged pushes its partner when
/// the 15s window would be exceeded. Preview playback loops the selected range.
class ClipTrimmer extends StatefulWidget {
  final String objectUrl;
  final int durationMs;
  final double aspectRatio; // width / height of the source video
  final List<String> filmstrip; // thumbnail data-URLs, evenly spaced
  final void Function(int startMs, int endMs) onSelectionChanged;

  const ClipTrimmer({
    super.key,
    required this.objectUrl,
    required this.durationMs,
    required this.aspectRatio,
    required this.filmstrip,
    required this.onSelectionChanged,
  });

  static const int minSelectionMs = 1000;
  static const int maxSelectionMs = 15000;

  @override
  State<ClipTrimmer> createState() => _ClipTrimmerState();
}

class _ClipTrimmerState extends State<ClipTrimmer> {
  static int _instanceCounter = 0;
  late final String _viewType;
  late final web.HTMLVideoElement _video;
  late double _startMs;
  late double _endMs;
  bool _playing = false;

  @override
  void initState() {
    super.initState();
    _startMs = 0;
    _endMs = widget.durationMs
        .clamp(ClipTrimmer.minSelectionMs, ClipTrimmer.maxSelectionMs)
        .toDouble();
    _viewType = 'nora-clip-trimmer-${_instanceCounter++}';

    _video = web.HTMLVideoElement()
      ..src = widget.objectUrl
      ..autoplay = false
      ..muted = true
      ..playsInline = true
      ..controls = false
      ..preload = 'auto';
    _video.style
      ..width = '100%'
      ..height = '100%'
      ..objectFit = 'contain'
      ..backgroundColor = '#000';
    // Loop playback inside the selection.
    _video.onTimeUpdate.listen((_) {
      if (_playing && _video.currentTime * 1000 >= _endMs) {
        _video.currentTime = _startMs / 1000;
      }
    });
    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) => _video);
    widget.onSelectionChanged(_startMs.round(), _endMs.round());
  }

  @override
  void dispose() {
    _video.pause();
    _video.removeAttribute('src');
    super.dispose();
  }

  void _onRangeChanged(RangeValues values) {
    var start = values.start;
    var end = values.end;
    final startMoved = start != _startMs;
    // Push the partner handle instead of blocking the drag.
    if (end - start > ClipTrimmer.maxSelectionMs) {
      if (startMoved) {
        end = start + ClipTrimmer.maxSelectionMs;
      } else {
        start = end - ClipTrimmer.maxSelectionMs;
      }
    }
    if (end - start < ClipTrimmer.minSelectionMs) {
      if (startMoved) {
        start = (end - ClipTrimmer.minSelectionMs).clamp(0, double.infinity);
        end = start + ClipTrimmer.minSelectionMs;
      } else {
        end = (start + ClipTrimmer.minSelectionMs)
            .clamp(0, widget.durationMs.toDouble());
        start = end - ClipTrimmer.minSelectionMs;
      }
    }
    setState(() {
      // Scrub the preview to whichever handle moved.
      _video.currentTime = (startMoved || start != _startMs ? start : end) / 1000;
      _pause();
      _startMs = start;
      _endMs = end;
    });
    widget.onSelectionChanged(start.round(), end.round());
  }

  void _pause() {
    _video.pause();
    _playing = false;
  }

  void _togglePlayback() {
    setState(() {
      if (_playing) {
        _pause();
      } else {
        _video.currentTime = _startMs / 1000;
        _video.muted = false;
        _video.play();
        _playing = true;
      }
    });
  }

  String _fmt(double ms) {
    final s = ms / 1000;
    return '${(s ~/ 60).toString().padLeft(1, '0')}:'
        '${(s % 60).toStringAsFixed(1).padLeft(4, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final selectionS = (_endMs - _startMs) / 1000;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Preview — capped height so portrait phone clips don't fill the page.
        ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 360),
          child: AspectRatio(
            aspectRatio: widget.aspectRatio.clamp(0.4, 2.5),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: HtmlElementView(viewType: _viewType),
            ),
          ),
        ),
        const SizedBox(height: 12),

        // Filmstrip with the range selection overlaid.
        SizedBox(
          height: 56,
          child: Stack(
            fit: StackFit.expand,
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: Row(
                  children: [
                    for (final thumb in widget.filmstrip)
                      Expanded(
                        child: Image.network(thumb, fit: BoxFit.cover, height: 56),
                      ),
                  ],
                ),
              ),
              SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  trackHeight: 56,
                  activeTrackColor: AppTheme.primary.withValues(alpha: 0.25),
                  inactiveTrackColor: Colors.black.withValues(alpha: 0.55),
                  rangeThumbShape: const RoundRangeSliderThumbShape(
                    enabledThumbRadius: 9,
                  ),
                  thumbColor: AppTheme.secondary,
                  overlayShape: SliderComponentShape.noOverlay,
                ),
                child: RangeSlider(
                  values: RangeValues(_startMs, _endMs),
                  min: 0,
                  max: widget.durationMs.toDouble(),
                  onChanged: _onRangeChanged,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),

        Row(
          children: [
            IconButton(
              onPressed: _togglePlayback,
              icon: Icon(
                _playing ? Icons.pause_circle : Icons.play_circle,
                color: AppTheme.secondary,
                size: 32,
              ),
              tooltip: _playing ? 'Pause' : 'Preview selection',
            ),
            Text(
              '${_fmt(_startMs)} – ${_fmt(_endMs)}',
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
            const Spacer(),
            Text(
              '${selectionS.toStringAsFixed(1)}s selected',
              style: TextStyle(
                color: selectionS > 15.0 ? AppTheme.danger : AppTheme.secondary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ],
    );
  }
}
