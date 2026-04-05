import 'package:flutter_riverpod/flutter_riverpod.dart';

class ReferralInfo {
  final String code;     // 8-char hex referral_code from the profiles table
  final String username; // the referrer's username, for display

  const ReferralInfo({required this.code, required this.username});
}

/// Holds a pending referral code across the /join → /signup flow.
/// Cleared once signup completes.
final referralInfoProvider = StateProvider<ReferralInfo?>((ref) => null);
