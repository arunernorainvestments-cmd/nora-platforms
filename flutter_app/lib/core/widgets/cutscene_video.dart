import 'dart:ui_web' as ui_web;
import 'package:flutter/material.dart';
import 'package:web/web.dart' as web;

/// Plays a chit's summon-cutscene MP4 via a native HTML <video> element
/// (Flutter web). Autoplays muted (browsers block un-muted autoplay); the
/// built-in controls let the user unmute to hear the moment's audio.
/// Used by the mint Preview step and the collection card detail.
class CutsceneVideo extends StatelessWidget {
  const CutsceneVideo({super.key, required this.url});
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
