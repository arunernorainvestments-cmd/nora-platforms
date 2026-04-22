import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Lightweight approval check used by the router.
// Re-evaluates whenever auth state changes.
// Returns: true = approved, false = pending, null = not logged in / loading.
final approvalStatusProvider = FutureProvider<bool?>((ref) async {
  final authState = await ref.watch(authStateProvider.future);
  final session = authState.session;
  if (session == null) return null;

  final data = await Supabase.instance.client
      .from('profiles')
      .select('is_approved')
      .eq('id', session.user.id)
      .maybeSingle();

  return data?['is_approved'] as bool? ?? false;
});

final authStateProvider = StreamProvider<AuthState>((ref) {
  return Supabase.instance.client.auth.onAuthStateChange;
});

final currentUserProvider = Provider<User?>((ref) {
  return Supabase.instance.client.auth.currentUser;
});

final authActionsProvider = Provider<AuthActions>((ref) => AuthActions());

class AuthActions {
  final _client = Supabase.instance.client;

  Future<void> signInWithEmail(String email, String password) async {
    await _client.auth.signInWithPassword(email: email, password: password);
  }

  Future<void> signUpWithEmail(String email, String password,
      {String? username, String? referredByCode}) async {
    // referred_by_code must arrive at trigger time via raw_user_meta_data
    final meta = <String, dynamic>{};
    if (referredByCode != null && referredByCode.isNotEmpty) {
      meta['referred_by_code'] = referredByCode;
    }

    final response = await _client.auth.signUp(
      email: email,
      password: password,
      data: meta.isNotEmpty ? meta : null,
    );

    if (username != null &&
        username.isNotEmpty &&
        response.user != null) {
      // Best-effort: update profile username. Silently ignored if no session yet
      // (email confirmation required).
      try {
        await _client
            .from('profiles')
            .update({'username': username})
            .eq('id', response.user!.id);
      } catch (_) {}
    }
  }

  Future<void> signInWithGoogle() async {
    await _client.auth.signInWithOAuth(
      OAuthProvider.google,
      redirectTo: 'com.noraplatforms://login-callback',
    );
  }

  Future<void> signOut() async {
    await _client.auth.signOut();
  }
}