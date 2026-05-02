import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/waitlist_models.dart';
import '../services/waitlist_service.dart';
import '../services/waitlist_storage.dart';

final _waitlistServiceProvider = Provider<WaitlistService>(
  (_) => WaitlistService(),
);

final _waitlistStorageProvider = Provider<WaitlistStorage>(
  (_) => WaitlistStorage(),
);

// Live count of waitlist signups, fetched from the waitlist-count edge function.
final waitlistCountProvider = FutureProvider<int>((ref) {
  return ref.read(_waitlistServiceProvider).fetchCount();
});

// ── State notifier ─────────────────────────────────────────────────────────────

class WaitlistNotifier extends StateNotifier<WaitlistState> {
  WaitlistNotifier(this._service, this._storage) : super(WaitlistLoading());

  final WaitlistService _service;
  final WaitlistStorage _storage;

  // Called by LaunchScreen on / when no URL token is present.
  Future<void> loadFromStorage() async {
    state = WaitlistLoading();
    try {
      final token = await _storage.getToken();
      if (token == null) {
        state = WaitlistAnonymous();
        return;
      }
      final response = await _service.fetchByToken(token);
      if (response != null) {
        state = WaitlistReturning(response);
      } else {
        await _storage.clearToken(); // stale token
        state = WaitlistAnonymous();
      }
    } catch (_) {
      state = WaitlistAnonymous();
    }
  }

  // Called by LaunchScreen on /w/:token.
  Future<void> loadFromToken(String urlToken) async {
    state = WaitlistLoading();
    try {
      final response = await _service.fetchByToken(urlToken);
      if (response != null) {
        await _storage.setToken(response.user.referralToken);
        state = WaitlistReturning(response);
      } else {
        state = WaitlistAnonymous(); // bad/expired token — fall through silently
      }
    } catch (_) {
      state = WaitlistAnonymous();
    }
  }

  // Throws on network/API error so the widget can show an inline error.
  Future<void> signup(String email, {String? referralToken}) async {
    final response = await _service.signup(email, referralToken: referralToken);
    await _storage.setToken(response.user.referralToken);
    state = WaitlistJoined(response);
  }
}

final waitlistStateProvider =
    StateNotifierProvider<WaitlistNotifier, WaitlistState>(
  (ref) => WaitlistNotifier(
    ref.read(_waitlistServiceProvider),
    ref.read(_waitlistStorageProvider),
  ),
);
