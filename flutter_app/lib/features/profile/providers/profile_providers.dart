import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ─────────────────────────────────────────────────────────────────────────────
// MODELS
// ─────────────────────────────────────────────────────────────────────────────

class UserProfile {
  final String id;
  final String? username;
  final String? displayName;
  final String? bio;
  final bool isCreator;

  const UserProfile({
    required this.id,
    this.username,
    this.displayName,
    this.bio,
    required this.isCreator,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        id: json['id'] as String,
        username: json['username'] as String?,
        displayName: json['display_name'] as String?,
        bio: json['bio'] as String?,
        isCreator: json['is_creator'] as bool? ?? false,
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// PROVIDERS
// ─────────────────────────────────────────────────────────────────────────────

final userProfileProvider = FutureProvider.autoDispose<UserProfile?>((ref) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return null;

  final data = await Supabase.instance.client
      .from('profiles')
      .select('id, username, display_name, bio, is_creator')
      .eq('id', userId)
      .single();

  return UserProfile.fromJson(data);
});

final profileTokenBalanceProvider = FutureProvider.autoDispose<int>((ref) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return 0;

  final data = await Supabase.instance.client
      .from('token_balances')
      .select('available_tokens')
      .eq('user_id', userId)
      .maybeSingle();

  return (data?['available_tokens'] as num?)?.toInt() ?? 0;
});

final spotlightTierProvider = FutureProvider.autoDispose<String?>((ref) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return null;

  final data = await Supabase.instance.client
      .from('spotlight_scores')
      .select('tier')
      .eq('user_id', userId)
      .maybeSingle();

  return data?['tier'] as String?;
});

// ─────────────────────────────────────────────────────────────────────────────
// ACTIONS
// ─────────────────────────────────────────────────────────────────────────────

class ProfileActions {
  final _client = Supabase.instance.client;

  Future<void> becomeCreator() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw Exception('Not authenticated');
    await _client
        .from('profiles')
        .update({'is_creator': true})
        .eq('id', userId);
  }

  Future<void> updateProfile({String? displayName, String? bio}) async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw Exception('Not authenticated');
    final updates = <String, dynamic>{
      if (displayName != null) 'display_name': displayName,
      if (bio != null) 'bio': bio,
    };
    if (updates.isNotEmpty) {
      await _client.from('profiles').update(updates).eq('id', userId);
    }
  }
}

final profileActionsProvider =
    Provider<ProfileActions>((ref) => ProfileActions());
