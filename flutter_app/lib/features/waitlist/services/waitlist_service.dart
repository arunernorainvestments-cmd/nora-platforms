import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/waitlist_models.dart';

class WaitlistService {
  Future<WaitlistResponse> signup(
    String email, {
    String? referralToken,
  }) async {
    final body = <String, dynamic>{'email': email};
    if (referralToken != null) body['referral_token'] = referralToken;

    try {
      final res = await Supabase.instance.client.functions.invoke(
        'waitlist-signup',
        body: body,
      );
      return WaitlistResponse.fromJson(res.data as Map<String, dynamic>);
    } on FunctionException catch (e) {
      throw Exception('Signup failed (${e.status}). Please try again.');
    }
  }

  // Returns null on 404 (bad/expired token) or any network error.
  Future<WaitlistResponse?> fetchByToken(String token) async {
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'waitlist-position',
        body: {'token': token},
      );
      return WaitlistResponse.fromJson(res.data as Map<String, dynamic>);
    } on FunctionException catch (e) {
      // 404 = token not found; treat as anonymous
      if (e.status == 404) return null;
      return null;
    } catch (_) {
      return null;
    }
  }

  Future<int> fetchCount() async {
    try {
      final res = await Supabase.instance.client.functions.invoke(
        'waitlist-count',
        method: HttpMethod.get,
      );
      final data = res.data as Map<String, dynamic>?;
      return (data?['total'] as num?)?.toInt() ?? 0;
    } catch (_) {
      return 0;
    }
  }
}
