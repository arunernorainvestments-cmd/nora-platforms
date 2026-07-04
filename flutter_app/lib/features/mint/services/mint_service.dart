import 'dart:typed_data';
import 'package:supabase_flutter/supabase_flutter.dart';

/// Client for the minting v2 staging flow (Minting_Workflow.md §1):
/// moment-ingest (ownership + source moderation) → upload trimmed clip + sample
/// frames to the private mint-staging bucket → moment-clip-attach (re-moderation
/// + similarity check). Paths MUST match what moment-clip-attach recomputes
/// server-side: {uid}/{momentId}/clip.mp4 + f0..f3.jpg.
class MintService {
  static SupabaseClient get _client => Supabase.instance.client;

  /// Registers + moderates the owned post. Returns the moment-ingest payload
  /// (moment_id, status, creator_handle, projected_tier, thumbnail_url, ...).
  static Future<Map<String, dynamic>> ingest(String postUrl) async {
    try {
      final res = await _client.functions.invoke(
        'moment-ingest',
        body: {'post_url': postUrl},
      );
      return Map<String, dynamic>.from(res.data as Map);
    } on FunctionException catch (e) {
      throw MintException(_messageFrom(e));
    }
  }

  /// Uploads the trimmed clip + moderation frames into the caller's staging
  /// prefix. Upsert on purpose: retrying a failed attach re-uses the paths.
  static Future<void> uploadStaged({
    required String momentId,
    required Uint8List video,
    required List<Uint8List> frames,
  }) async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) throw const MintException('Not signed in');
    final storage = _client.storage.from('mint-staging');
    final prefix = '$uid/$momentId';
    await storage.uploadBinary(
      '$prefix/clip.mp4',
      video,
      fileOptions: const FileOptions(contentType: 'video/mp4', upsert: true),
    );
    for (var i = 0; i < frames.length; i++) {
      await storage.uploadBinary(
        '$prefix/f$i.jpg',
        frames[i],
        fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true),
      );
    }
  }

  /// Registers the staged upload against the moment. Returns the attach payload
  /// (clip_status: attached | similarity_flagged | rejected, ...).
  static Future<Map<String, dynamic>> attachClip({
    required String momentId,
    required int trimStartMs,
    required int trimEndMs,
    required bool keepAudio,
  }) async {
    try {
      final res = await _client.functions.invoke(
        'moment-clip-attach',
        body: {
          'moment_id': momentId,
          'trim_start_ms': trimStartMs,
          'trim_end_ms': trimEndMs,
          'keep_audio': keepAudio,
        },
      );
      return Map<String, dynamic>.from(res.data as Map);
    } on FunctionException catch (e) {
      throw MintException(_messageFrom(e));
    }
  }

  static String _messageFrom(FunctionException e) {
    final d = e.details;
    if (d is Map) {
      final msg = d['detail'] ?? d['error'];
      if (msg != null) return msg.toString();
    }
    return 'Request failed (${e.status})';
  }
}

class MintException implements Exception {
  final String message;
  const MintException(this.message);
  @override
  String toString() => message;
}
