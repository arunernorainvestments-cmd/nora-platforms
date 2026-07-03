import 'dart:async';
import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

// The launch-night rocket cutscene. Plays assets/video/launch_rocket.mp4
// (muted — browsers block un-muted autoplay without a user gesture).
// If the file is missing or fails to load, [onUnavailable] fires so the
// caller can fall back to the built-in rocket animation.
class RocketVideo extends StatefulWidget {
  final VoidCallback onEnded;
  final VoidCallback onUnavailable;

  const RocketVideo({
    super.key,
    required this.onEnded,
    required this.onUnavailable,
  });

  @override
  State<RocketVideo> createState() => _RocketVideoState();
}

class _RocketVideoState extends State<RocketVideo> {
  static int _instanceCounter = 0;
  late final String _viewType;
  Timer? _loadTimeout;
  bool _settled = false; // ended/failed already reported

  @override
  void initState() {
    super.initState();
    _viewType = 'nora-rocket-video-${_instanceCounter++}';

    ui_web.platformViewRegistry.registerViewFactory(_viewType, (int _) {
      final video = web.HTMLVideoElement()
        ..src = ui_web.assetManager
            .getAssetUrl('assets/video/launch_rocket.mp4')
        ..autoplay = true
        ..muted = true
        ..playsInline = true
        ..controls = false
        ..preload = 'auto';
      video.style
        ..width = '100%'
        ..height = '100%'
        ..objectFit = 'cover'
        ..backgroundColor = '#000';

      video.onCanPlay.listen((_) => _loadTimeout?.cancel());
      video.onEnded.listen((_) => _settle(widget.onEnded));
      video.onError.listen((_) => _settle(widget.onUnavailable));
      return video;
    });

    // Missing asset on some CDNs stalls instead of erroring — treat a video
    // that can't start within 6s as unavailable.
    _loadTimeout = Timer(const Duration(seconds: 6), () {
      _settle(widget.onUnavailable);
    });
  }

  void _settle(VoidCallback callback) {
    if (_settled || !mounted) return;
    _settled = true;
    _loadTimeout?.cancel();
    callback();
  }

  @override
  void dispose() {
    _loadTimeout?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return HtmlElementView(viewType: _viewType);
  }
}
