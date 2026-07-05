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

  /// The recommend/classify stage: derives the creative inputs generation needs.
  /// Returns { family, suggested_name, subject_desc, chit_type }. Family is
  /// content-derived (Hard Rule 34) — the UI shows it locked.
  static Future<Map<String, dynamic>> classify(String momentId) async {
    try {
      final res = await _client.functions.invoke(
        'moment-classify',
        body: {'moment_id': momentId},
      );
      return Map<String, dynamic>.from(res.data as Map);
    } on FunctionException catch (e) {
      throw MintException(_messageFrom(e));
    }
  }

  /// Runs the cinematic generation pipeline for the reviewed card. Returns the
  /// mint payload (status, chit_id, card_art_url, mp4_cutscene_url, tier, ...) or,
  /// when a self-minted card already occupies the single slot, an
  /// `error: self_mint_slot_occupied` payload with `occupied_chit_id` for the
  /// swap-confirm flow. HTTP-level failures still surface as [MintException].
  static Future<Map<String, dynamic>> generate({
    required String momentId,
    required String family,
    required String chitType,
    required String subjectDesc,
    String? name,
    String? swapOfChitId,
    bool swapConfirm = false,
  }) async {
    try {
      final res = await _client.functions.invoke(
        'cinematic-mint',
        body: {
          'moment_id': momentId,
          'family': family,
          'chit_type': chitType,
          'subject_desc': subjectDesc,
          if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
          if (swapOfChitId != null) 'swap_of_chit_id': swapOfChitId,
          if (swapConfirm) 'swap_confirm': true,
        },
      );
      return Map<String, dynamic>.from(res.data as Map);
    } on FunctionException catch (e) {
      // The 409 slot-occupied response carries a structured body we want to read
      // rather than a bare message — surface it to the caller as data.
      final d = e.details;
      if (d is Map && d['error'] == 'self_mint_slot_occupied') {
        return Map<String, dynamic>.from(d);
      }
      throw MintException(_messageFrom(e));
    }
  }

  /// Loads the freshly minted chit's full row (tier-derived aura/atk/hp/keywords)
  /// so the preview can render the complete card face. Owner-scoped by RLS.
  static Future<Map<String, dynamic>?> fetchChit(String chitId) async {
    final res = await _client
        .from('moment_chits')
        .select(
            'id, name, chit_type, archetype_family, tier, aura_cost, atk, hp, '
            'keywords, card_art_url, mp4_cutscene_url, original_minter_handle, '
            'source_platform, rules_text, flavor_text, card_serial')
        .eq('id', chitId)
        .maybeSingle();
    return res == null ? null : Map<String, dynamic>.from(res);
  }

  /// Marks the chit as previewed (Hard Rule 39 gate) — called once the user has
  /// seen the generated card + cutscene in the web preview.
  static Future<void> recordPreview(String chitId) async {
    await _client.rpc('chit_record_preview', params: {'p_chit_id': chitId});
  }

  /// Activates the previewed chit into the user's collection.
  static Future<void> finalizePreview(String chitId) async {
    await _client.rpc('chit_finalize_preview', params: {'p_chit_id': chitId});
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
