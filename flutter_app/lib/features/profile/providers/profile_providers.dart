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
  final bool isCreator; // spotlight-score eligibility (is_creator column)
  final bool isMarketMaker;
  final bool pendingOptOut;
  final bool popularityScorePublic;
  final String? referralCode;

  const UserProfile({
    required this.id,
    this.username,
    this.displayName,
    this.bio,
    required this.isCreator,
    required this.isMarketMaker,
    required this.pendingOptOut,
    required this.popularityScorePublic,
    this.referralCode,
  });

  factory UserProfile.fromJson(Map<String, dynamic> json) => UserProfile(
        id: json['id'] as String,
        username: json['username'] as String?,
        displayName: json['display_name'] as String?,
        bio: json['bio'] as String?,
        isCreator: json['is_creator'] as bool? ?? false,
        isMarketMaker: json['is_market_maker'] as bool? ?? false,
        pendingOptOut: json['pending_opt_out'] as bool? ?? false,
        popularityScorePublic: json['popularity_score_public'] as bool? ?? false,
        referralCode: json['referral_code'] as String?,
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
      .select(
          'id, username, display_name, bio, is_creator, is_market_maker, '
          'pending_opt_out, popularity_score_public, referral_code')
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

  Future<void> becomeMarketMaker() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw Exception('Not authenticated');
    await _client.from('profiles').update({
      'is_market_maker': true,
      'is_creator': true, // enables spotlight-score eligibility
      'popularity_score_public': true,
      'market_maker_opted_in_at': DateTime.now().toUtc().toIso8601String(),
    }).eq('id', userId);
  }

  Future<bool> checkHasOpenMarkets() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) return false;
    final result = await _client
        .from('markets')
        .select('id')
        .eq('creator_id', userId)
        .eq('status', 'open')
        .limit(1);
    return (result as List).isNotEmpty;
  }

  Future<void> optOutMarketMaker() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw Exception('Not authenticated');

    final hasOpen = await checkHasOpenMarkets();
    if (hasOpen) {
      await _client.from('profiles').update({
        'pending_opt_out': true,
      }).eq('id', userId);
    } else {
      await _client.from('profiles').update({
        'is_market_maker': false,
        'popularity_score_public': false,
        'pending_opt_out': false,
      }).eq('id', userId);
    }
  }

  Future<void> resumeMarketMaker() async {
    final userId = _client.auth.currentUser?.id;
    if (userId == null) throw Exception('Not authenticated');
    await _client.from('profiles').update({
      'pending_opt_out': false,
    }).eq('id', userId);
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
