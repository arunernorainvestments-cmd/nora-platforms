import 'package:web/web.dart' as web;

// Tiny localStorage-backed boolean flags (same pattern as WaitlistStorage).
// Falls back to in-memory storage on Safari private mode (localStorage throws).
class LocalFlags {
  static final Map<String, bool> _memory = {};

  static bool get(String key) {
    try {
      return web.window.localStorage.getItem(key) == '1';
    } catch (_) {
      return _memory[key] ?? false;
    }
  }

  static void set(String key, bool value) {
    try {
      if (value) {
        web.window.localStorage.setItem(key, '1');
      } else {
        web.window.localStorage.removeItem(key);
      }
    } catch (_) {
      _memory[key] = value;
    }
  }
}
