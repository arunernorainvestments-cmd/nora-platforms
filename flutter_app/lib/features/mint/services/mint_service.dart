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

  /// Cloud-trim fallback, step 1: stages the RAW picked file so the stitch
  /// worker can cut it (used when the in-browser wasm trimmer runs out of
  /// memory). 200MB bucket cap; declared as mp4 (the worker sniffs the real
  /// container, and mint-staging's mime allowlist is mp4/jpeg only).
  static Future<void> uploadRawSource({
    required String momentId,
    required Uint8List bytes,
  }) async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) throw const MintException('Not signed in');
    await _client.storage.from('mint-staging').uploadBinary(
          '$uid/$momentId/raw_source.mp4',
          bytes,
          fileOptions: const FileOptions(contentType: 'video/mp4', upsert: true),
        );
  }

  /// Cloud-trim fallback, step 2: the stitch worker cuts + normalizes the raw
  /// upload into the exact artifacts the browser path produces (clip.mp4 +
  /// f0..f3.jpg at the staging prefix), so [attachClip] runs unchanged after.
  static Future<void> trimRemote({
    required String momentId,
    required int trimStartMs,
    required int trimEndMs,
    required bool keepAudio,
  }) async {
    try {
      await _client.functions.invoke('mint-trim-remote', body: {
        'moment_id': momentId,
        'trim_start_ms': trimStartMs,
        'trim_end_ms': trimEndMs,
        'keep_audio': keepAudio,
      });
    } on FunctionException catch (e) {
      throw MintException(_messageFrom(e));
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
  /// Returns { family, suggested_name, subject_desc, chit_type, effect_* }. Family
  /// defaults to content-derived (automatic); pass [familyOverride] to let the user
  /// pick one of the 10 families instead — the effect is then re-selected server-side
  /// from that family's authored library, so power never changes (Hard Rule 34).
  static Future<Map<String, dynamic>> classify(
    String momentId, {
    String? familyOverride,
    String? subjectDesc,
    String? chitType,
  }) async {
    try {
      final res = await _client.functions.invoke(
        'moment-classify',
        body: {
          'moment_id': momentId,
          if (familyOverride != null) 'family_override': familyOverride,
          if (subjectDesc != null && subjectDesc.trim().isNotEmpty)
            'subject_desc': subjectDesc.trim(),
          if (chitType != null) 'chit_type': chitType,
        },
      );
      return Map<String, dynamic>.from(res.data as Map);
    } on FunctionException catch (e) {
      throw MintException(_messageFrom(e));
    }
  }

  /// Kicks off the cinematic generation pipeline for the reviewed card. The
  /// server validates + guards synchronously, then generates in a background job
  /// and returns `status: accepted` + `job_id` immediately (the old synchronous
  /// path hit the edge-runtime wall clock — HTTP 546). Poll [fetchMintJob] until
  /// the job leaves `running`; its `result` mirrors the old mint payload. When a
  /// self-minted card already occupies the single slot this returns the
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
    String? collectionId,
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
          // Collections spec N2: mint this card into the caller's collection
          // (slot-exempt lane; the server validates minter eligibility).
          if (collectionId != null) 'collection_id': collectionId,
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

  /// Reads the caller's mint job row (owner-scoped RLS) — stage drives the
  /// progressive loader; a terminal status carries the mint payload in `result`.
  static Future<Map<String, dynamic>?> fetchMintJob(String jobId) async {
    final res = await _client
        .from('mint_jobs')
        .select('id, stage, status, chit_id, error, detail, result, updated_at')
        .eq('id', jobId)
        .maybeSingle();
    return res == null ? null : Map<String, dynamic>.from(res);
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

  /// Discards a pending (un-finalized) chit from the Preview step: retires it, frees
  /// the one self-mint slot, and deletes its media. A finalized chit is refused (409).
  static Future<void> cancelMint(String chitId) async {
    try {
      await _client.functions.invoke('mint-cancel', body: {'chit_id': chitId});
    } on FunctionException catch (e) {
      throw MintException(_messageFrom(e));
    }
  }

  /// Deletes a FINALIZED card the user minted (collection "Delete card"): retires it,
  /// deletes its media, frees the self-mint slot, and releases the source moment so
  /// the same moment can be minted again. Server refuses if copies are held by other
  /// users, or the chit is wager-escrowed or listed on the market.
  static Future<void> deleteChit(String chitId) async {
    try {
      await _client.functions.invoke('mint-cancel',
          body: {'chit_id': chitId, 'allow_finalized': true});
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
