import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:web/web.dart' as web;

// Generates a SHA-256 hash of browser signals for poll anti-abuse fingerprinting.
// Never sends raw browser data — only the hash is transmitted.
// Only available on Flutter web. Returns null on non-web targets.
Future<String?> getDeviceFingerprint() async {
  try {
    final nav = web.window.navigator;
    final scr = web.window.screen;

    final signals = [
      nav.userAgent,
      nav.language,
      scr.width.toString(),
      scr.height.toString(),
      DateTime.now().timeZoneOffset.inMinutes.toString(),
      scr.colorDepth.toString(),
    ].join('|');

    final digest = sha256.convert(utf8.encode(signals));
    return digest.toString();
  } catch (_) {
    return null;
  }
}
