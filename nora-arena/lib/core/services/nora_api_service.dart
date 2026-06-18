import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../config/nora_api_config.dart';
import '../models/verified_license.dart';

/// Client for the N.O.R.A. licensing REST API (lkn-verify).
///
/// This is the SOURCE OF TRUTH for whether a licensed character may be used
/// (CLAUDE.md rule 4). All calls send the `X-NORA-API-Key` header. Failures are
/// logged and degrade to empty/false — never thrown (CLAUDE.md rule 8).
class NoraApiService {
  final http.Client _http;
  NoraApiService([http.Client? client]) : _http = client ?? http.Client();

  Map<String, String> get _headers => {'X-NORA-API-Key': NoraApiConfig.apiKey};

  /// List the user's active game-use licenses (doc6 License Sync — list mode).
  Future<List<VerifiedLicense>> listActiveGameLicenses(String noraUserId) async {
    try {
      final res = await _http.get(
        NoraApiConfig.verifyUrl({
          'licensee_nora_id': noraUserId,
          'use_category': 'entertainment_game',
        }),
        headers: _headers,
      );
      if (res.statusCode != 200) {
        debugPrint('[NoraApi] list licenses HTTP ${res.statusCode}');
        return [];
      }
      final body = jsonDecode(res.body);
      if (body is! List) return [];
      return body
          .map((j) => VerifiedLicense.fromJson(j as Map<String, dynamic>))
          .where((l) => l.isPlayable)
          .toList();
    } catch (e) {
      debugPrint('[NoraApi] list licenses failed: $e');
      return [];
    }
  }

  /// Re-verify a single license immediately before battle start (signed mode).
  /// Returns the verified record (with signature) or null on any failure.
  Future<VerifiedLicense?> verifyForBattle(String licenseId) async {
    try {
      final res = await _http.get(
        NoraApiConfig.verifyUrl({
          'license_id': licenseId,
          'use_category': 'entertainment_game',
        }),
        headers: _headers,
      );
      if (res.statusCode != 200) return null;
      final lic = VerifiedLicense.fromJson(
          jsonDecode(res.body) as Map<String, dynamic>);
      // TODO(battle phase): verify lic.signature against NoraApiConfig.publicKeyUrl
      // using package:crypto + WebCrypto-equivalent ECDSA P-256 before trusting
      // an offline/cached result. Online responses are already trusted (TLS).
      return lic.isPlayable ? lic : null;
    } catch (e) {
      debugPrint('[NoraApi] verifyForBattle failed: $e');
      return null;
    }
  }
}
