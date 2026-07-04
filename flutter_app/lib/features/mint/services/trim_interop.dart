import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:typed_data';

// Bindings for web/js/nora_trim.js — the browser-side clip trimmer
// (ffmpeg.wasm, lazy-loaded on first use). Web-only, like the rest of the app.
// Property access uses js_interop_unsafe (not extension types) because the
// app's language version floor is Dart 3.0.

@JS('noraTrim')
external JSObject? get _noraTrim;

@JS('noraTrim.load')
external JSPromise<JSAny?> _load();

@JS('noraTrim.probe')
external JSPromise<JSObject> _probe(JSString objectUrl);

@JS('noraTrim.filmstrip')
external JSPromise<JSArray<JSString>> _filmstrip(
    JSString objectUrl, JSNumber count, JSNumber thumbHeight);

@JS('noraTrim.process')
external JSPromise<JSObject> _process(JSString objectUrl, JSNumber startMs,
    JSNumber endMs, JSBoolean keepAudio, JSFunction onProgress);

class ClipProbe {
  final int durationMs;
  final int width;
  final int height;
  const ClipProbe(this.durationMs, this.width, this.height);
}

class TrimmedClip {
  final Uint8List video; // normalized H.264 mp4
  final List<Uint8List> frames; // 4 moderation sample JPEGs
  const TrimmedClip(this.video, this.frames);
}

/// Thin async facade over the JS shim. Throws [StateError] with a readable
/// message when the shim is missing or the browser can't decode the file.
class TrimEngine {
  static void _ensureShim() {
    if (_noraTrim == null) {
      throw StateError('Trimmer unavailable — js/nora_trim.js failed to load');
    }
  }

  /// Loads ffmpeg.wasm (~31MB, one-time). Safe to call repeatedly.
  static Future<void> warmUp() async {
    _ensureShim();
    await _load().toDart;
  }

  static Future<ClipProbe> probe(String objectUrl) async {
    _ensureShim();
    final r = await _probe(objectUrl.toJS).toDart;
    return ClipProbe(
      r.getProperty<JSNumber>('durationMs'.toJS).toDartInt,
      r.getProperty<JSNumber>('width'.toJS).toDartInt,
      r.getProperty<JSNumber>('height'.toJS).toDartInt,
    );
  }

  static Future<List<String>> filmstrip(String objectUrl,
      {int count = 8, int thumbHeight = 56}) async {
    _ensureShim();
    final r =
        await _filmstrip(objectUrl.toJS, count.toJS, thumbHeight.toJS).toDart;
    return r.toDart.map((s) => s.toDart).toList();
  }

  static Future<TrimmedClip> process({
    required String objectUrl,
    required int startMs,
    required int endMs,
    required bool keepAudio,
    required void Function(double) onProgress,
  }) async {
    _ensureShim();
    final cb = ((JSNumber p) => onProgress(p.toDartDouble)).toJS;
    final r = await _process(
            objectUrl.toJS, startMs.toJS, endMs.toJS, keepAudio.toJS, cb)
        .toDart;
    final video = r.getProperty<JSUint8Array>('video'.toJS).toDart;
    final frames = r
        .getProperty<JSArray<JSUint8Array>>('frames'.toJS)
        .toDart
        .map((f) => f.toDart)
        .toList();
    return TrimmedClip(video, frames);
  }
}
