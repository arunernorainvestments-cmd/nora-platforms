import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// ─────────────────────────────────────────────────────────────────────────────
// TOKEN PACKAGES
// ─────────────────────────────────────────────────────────────────────────────

class TokenPackage {
  final String id;
  final String label;
  final int tokens;
  final String priceDisplay;
  final String? badge;

  const TokenPackage({
    required this.id,
    required this.label,
    required this.tokens,
    required this.priceDisplay,
    this.badge,
  });
}

const kTokenPackages = [
  TokenPackage(id: 'starter', label: 'Starter',  tokens: 120,  priceDisplay: r'$0.99'),
  TokenPackage(id: 'popular', label: 'Popular',  tokens: 650,  priceDisplay: r'$4.99',  badge: 'Most Popular'),
  TokenPackage(id: 'pro',     label: 'Pro',      tokens: 1650, priceDisplay: r'$9.99',  badge: 'Best Value'),
  TokenPackage(id: 'elite',   label: 'Elite',    tokens: 3500, priceDisplay: r'$19.99'),
];

// ─────────────────────────────────────────────────────────────────────────────
// MODELS
// ─────────────────────────────────────────────────────────────────────────────

class TokenBalance {
  final int availableTokens;
  final int lifetimeEarned;
  final int lifetimeSpent;

  const TokenBalance({
    required this.availableTokens,
    required this.lifetimeEarned,
    required this.lifetimeSpent,
  });

  factory TokenBalance.fromJson(Map<String, dynamic> json) => TokenBalance(
        availableTokens: (json['available_tokens'] as num?)?.toInt() ?? 0,
        lifetimeEarned: (json['lifetime_earned'] as num?)?.toInt() ?? 0,
        lifetimeSpent: (json['lifetime_spent'] as num?)?.toInt() ?? 0,
      );

  static const empty = TokenBalance(
    availableTokens: 0,
    lifetimeEarned: 0,
    lifetimeSpent: 0,
  );
}

class TokenTransaction {
  final String id;
  final String type; // signup_bonus | bet_won | bet_lost | promoted | purchased | verification_bonus
  final int amount;
  final String? description;
  final DateTime createdAt;

  const TokenTransaction({
    required this.id,
    required this.type,
    required this.amount,
    this.description,
    required this.createdAt,
  });

  factory TokenTransaction.fromJson(Map<String, dynamic> json) =>
      TokenTransaction(
        id: json['id'] as String,
        type: json['type'] as String,
        amount: (json['amount'] as num).toInt(),
        description: json['description'] as String?,
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  /// Whether this transaction adds tokens to the user's balance.
  bool get isCredit => amount > 0;

  String get typeIcon => switch (type) {
        'signup_bonus' => '🎁',
        'bet_won' => '🏆',
        'bet_lost' => '💸',
        'promoted' => '📣',
        'purchased' => '🛒',
        'verification_bonus' => '✅',
        _ => '🪙',
      };

  String get typeLabel => switch (type) {
        'signup_bonus' => 'Signup Bonus',
        'bet_won' => 'Bet Won',
        'bet_lost' => 'Bet Lost',
        'promoted' => 'Promoted Creator',
        'purchased' => 'Tokens Purchased',
        'verification_bonus' => 'Platform Connected',
        _ => 'Token Activity',
      };

  String get amountDisplay =>
      isCredit ? '+$amount' : '$amount'; // negatives already carry the minus
}

// ─────────────────────────────────────────────────────────────────────────────
// PROVIDERS
// ─────────────────────────────────────────────────────────────────────────────

final tokenBalanceProvider =
    FutureProvider.autoDispose<TokenBalance>((ref) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return TokenBalance.empty;

  final data = await Supabase.instance.client
      .from('token_balances')
      .select('available_tokens, lifetime_earned, lifetime_spent')
      .eq('user_id', userId)
      .maybeSingle();

  if (data == null) return TokenBalance.empty;
  return TokenBalance.fromJson(data);
});

final tokenTransactionsProvider =
    FutureProvider.autoDispose<List<TokenTransaction>>((ref) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return [];

  final data = await Supabase.instance.client
      .from('token_transactions')
      .select('id, type, amount, description, created_at')
      .eq('user_id', userId)
      .order('created_at', ascending: false)
      .limit(10);

  return (data as List)
      .map((e) => TokenTransaction.fromJson(e as Map<String, dynamic>))
      .toList();
});
