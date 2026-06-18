import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Config for the N.O.R.A. licensing REST API (separate from Supabase).
///
/// The verify endpoint is reachable two ways:
///   • prod gateway:  https://api.noraplatforms.com/v1/verify
///   • direct fn URL: https://<ref>.functions.supabase.co/lkn-verify
/// We normalise so the rest of the app always calls [verifyUrl].
class NoraApiConfig {
  static String get _base =>
      dotenv.env['NORA_API_BASE'] ?? 'https://api.noraplatforms.com/v1';

  /// The N.O.R.A. API key for this app (issued by lkn-register-api-key).
  /// NOT a Supabase key. Sent as the `X-NORA-API-Key` header.
  static String get apiKey => dotenv.env['NORA_API_KEY'] ?? '';

  /// Resolves the correct verify path for whichever base is configured.
  /// Gateway exposes `/verify`; the raw function is `/lkn-verify`.
  static Uri verifyUrl(Map<String, String> query) {
    final base = _base.replaceFirst(RegExp(r'/$'), '');
    final path = base.contains('functions.supabase.co') ? 'lkn-verify' : 'verify';
    return Uri.parse('$base/$path').replace(queryParameters: query);
  }

  /// Published ECDSA P-256 public key used to verify signed responses.
  static const String publicKeyUrl =
      'https://noraplatforms.com/.well-known/nora-public-key.pem';
}
