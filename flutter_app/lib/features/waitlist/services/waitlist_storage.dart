import 'package:web/web.dart' as web;

// Persists the user's referral token in localStorage so returning visitors
// are auto-detected as WaitlistReturning without re-submitting their email.
// Falls back to in-memory storage on Safari private mode (localStorage throws).
class WaitlistStorage {
  static const _key = 'waitlist_token';

  String? _memory;

  Future<String?> getToken() async {
    try {
      final val = web.window.localStorage.getItem(_key);
      return (val == null || val.isEmpty) ? null : val;
    } catch (_) {
      return _memory;
    }
  }

  Future<void> setToken(String token) async {
    try {
      web.window.localStorage.setItem(_key, token);
    } catch (_) {
      _memory = token;
    }
  }

  Future<void> clearToken() async {
    try {
      web.window.localStorage.removeItem(_key);
    } catch (_) {
      _memory = null;
    }
  }
}
