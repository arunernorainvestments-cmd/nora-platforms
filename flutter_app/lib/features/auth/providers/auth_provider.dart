import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

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