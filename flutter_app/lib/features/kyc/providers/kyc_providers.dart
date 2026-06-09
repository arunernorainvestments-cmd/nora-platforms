import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Current user's identity-verification state, read from kyc_verifications.
class KycInfo {
  final String status; // 'none' | 'pending' | 'approved' | 'rejected' | 'expired'
  final DateTime? expiresAt;
  final String? rejectedReason;

  const KycInfo({required this.status, this.expiresAt, this.rejectedReason});

  bool get isApproved =>
      status == 'approved' &&
      (expiresAt == null || expiresAt!.isAfter(DateTime.now()));
  bool get isPending => status == 'pending';
  bool get isRejected => status == 'rejected';
  bool get isUnverified => !isApproved && !isPending;

  factory KycInfo.fromRow(Map<String, dynamic>? row) {
    if (row == null) return const KycInfo(status: 'none');
    return KycInfo(
      status: row['status'] as String? ?? 'none',
      expiresAt: row['expires_at'] != null
          ? DateTime.tryParse(row['expires_at'] as String)
          : null,
      rejectedReason: row['rejected_reason'] as String?,
    );
  }
}

final myKycProvider = FutureProvider.autoDispose<KycInfo>((ref) async {
  final uid = Supabase.instance.client.auth.currentUser?.id;
  if (uid == null) return const KycInfo(status: 'none');
  final row = await Supabase.instance.client
      .from('kyc_verifications')
      .select('status, expires_at, rejected_reason')
      .eq('user_id', uid)
      .maybeSingle();
  return KycInfo.fromRow(row);
});

final kycServiceProvider = Provider<KycService>((ref) => KycService(ref));

class KycService {
  KycService(this.ref);
  final Ref ref;

  /// Starts verification. In live mode returns a Stripe-hosted URL to redirect to;
  /// in sim mode the user is approved in place and this returns null. Either way the
  /// caller should invalidate [myKycProvider] (done here) and react to the result.
  Future<String?> startVerification() async {
    final res = await Supabase.instance.client.functions
        .invoke('kyc-create-session');
    final data = res.data as Map<String, dynamic>?;
    ref.invalidate(myKycProvider);
    return data?['url'] as String?;
  }
}
