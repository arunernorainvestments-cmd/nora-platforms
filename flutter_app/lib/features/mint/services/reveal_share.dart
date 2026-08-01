import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:flutter/services.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// The mint-reveal share loop (Standard Playset spec S4.1).
///
/// Every completed mint gets a shareable 9:16 reveal composed server-side
/// (`mint-reveal-compose`). This is the client half: fetch/compose the asset,
/// then hand it to the platform's share sheet with one tap.
///
/// Flutter web has no universal share sheet, so we use `navigator.share` where
/// the browser provides it and fall back to copy-link + open-asset everywhere
/// else. Sharing is never gated behind KYC or any other friction — the whole
/// point is that the minter distributes for us (spec S4 "DO NOT").
class RevealShare {
  const RevealShare({
    required this.ready,
    required this.assetUrl,
    required this.caption,
    required this.joinUrl,
    required this.reason,
  });

  /// A composed reveal MP4 exists and can be shared/downloaded.
  final bool ready;
  final String? assetUrl;
  final String caption;

  /// The invite link, already carrying this user's referral code. Reward logic
  /// is deliberately deferred to the challenge framework — and there are never
  /// card rewards for referrals (sybil guard).
  final String joinUrl;

  /// Why the asset is missing, when it is (`composer_unavailable`, …). The UI
  /// still shares the link + card art in that case — never a dead end.
  final String? reason;

  String get shareText => '$caption\n$joinUrl';
}

class RevealShareService {
  static SupabaseClient get _client => Supabase.instance.client;

  /// Composes (or re-uses) the reveal asset for a chit the caller holds.
  static Future<RevealShare> compose(String chitId, {bool force = false}) async {
    final res = await _client.functions.invoke(
      'mint-reveal-compose',
      body: {'chit_id': chitId, if (force) 'force': true},
    );
    final data = Map<String, dynamic>.from(res.data as Map);
    final share = (data['share'] as Map?)?.cast<String, dynamic>() ?? const {};
    return RevealShare(
      ready: data['ok'] == true && data['asset_url'] != null,
      assetUrl: data['asset_url'] as String?,
      caption: (share['caption'] ?? 'My moment is a playable card now.').toString(),
      joinUrl: (share['join_url'] ?? 'https://noraplatforms.com/join').toString(),
      reason: data['reason'] as String?,
    );
  }

  /// True when this browser exposes the Web Share API.
  static bool get canNativeShare {
    final nav = _navigator;
    return nav != null && nav.has('share');
  }

  /// Opens the native share sheet. Returns false when it is unavailable or the
  /// user dismissed it, so the caller can fall back to copy-link.
  static Future<bool> nativeShare(RevealShare share) async {
    final nav = _navigator;
    if (nav == null || !nav.has('share')) return false;
    try {
      final payload = JSObject()
        ..setProperty('title'.toJS, 'My NORA card'.toJS)
        ..setProperty('text'.toJS, share.caption.toJS)
        ..setProperty('url'.toJS, (share.assetUrl ?? share.joinUrl).toJS);
      final result = nav.callMethod<JSPromise<JSAny?>>('share'.toJS, payload);
      await result.toDart;
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Clipboard fallback: the caption plus the join link.
  static Future<void> copyLink(RevealShare share) =>
      Clipboard.setData(ClipboardData(text: share.shareText));
}

@JS('navigator')
external JSObject? get _navigator;
