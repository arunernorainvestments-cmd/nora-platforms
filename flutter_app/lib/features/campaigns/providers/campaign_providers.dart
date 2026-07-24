import 'dart:typed_data';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../auth/providers/auth_provider.dart';

/// Clip Campaigns — Collections spec Phase N7, §1.6.
///
/// A bounty board for raw clips: a Market Maker posts what they want and what
/// they pay (budget escrowed at creation); clippers submit; EVERY submission
/// passes platform moderation before the Market Maker can see it; the Market
/// Maker accepts winners and payment settles from escrow.
///
/// The moderation wall is enforced in RLS (mig 176), not here — a submission in
/// `submitted` / `in_moderation` / `rejected` is simply not readable by the
/// Market Maker, so this layer cannot leak one even by accident.
///
/// Money is integer USD cents on the sim/live-switched rail; the client never
/// does float math and never crosses the currency wall (Hard Rule 33).

class ClipCampaign {
  const ClipCampaign({
    required this.id,
    required this.marketMakerUserId,
    required this.title,
    required this.brief,
    required this.payoutPerClipCents,
    required this.maxAccepted,
    required this.acceptedCount,
    required this.escrowRemainingCents,
    required this.status,
    required this.deadline,
    required this.mintEligible,
  });

  final String id;
  final String marketMakerUserId;
  final String title;
  final String brief;
  final int payoutPerClipCents;
  final int maxAccepted;
  final int acceptedCount;
  final int escrowRemainingCents;
  final String status;
  final DateTime deadline;

  /// REPO-CHECK 1.6: true only when the campaign is tethered to a post the
  /// Market Maker owns, which is what lets an accepted clip feed a mint at all.
  final bool mintEligible;

  bool get isOpen => status == 'open';
  int get slotsLeft => maxAccepted - acceptedCount;
  String get payoutLabel => '\$${(payoutPerClipCents / 100).toStringAsFixed(2)}';

  factory ClipCampaign.fromRow(Map<String, dynamic> r) => ClipCampaign(
        id: r['id'] as String,
        marketMakerUserId: r['market_maker_user_id'] as String,
        title: r['title'] as String,
        brief: r['brief'] as String,
        payoutPerClipCents: r['payout_per_clip_cents'] as int,
        maxAccepted: r['max_accepted'] as int,
        acceptedCount: r['accepted_count'] as int? ?? 0,
        escrowRemainingCents: r['escrow_remaining_cents'] as int? ?? 0,
        status: r['status'] as String,
        deadline: DateTime.parse(r['deadline'] as String),
        mintEligible: r['source_moment_id'] != null,
      );
}

class ClipSubmission {
  const ClipSubmission({
    required this.id,
    required this.campaignId,
    required this.clipperUserId,
    required this.clipPath,
    required this.status,
    required this.note,
    required this.createdAt,
  });

  final String id;
  final String campaignId;
  final String clipperUserId;
  final String clipPath;
  final String status;
  final String? note;
  final DateTime createdAt;

  bool get isPaid => status == 'paid';

  factory ClipSubmission.fromRow(Map<String, dynamic> r) => ClipSubmission(
        id: r['id'] as String,
        campaignId: r['campaign_id'] as String,
        clipperUserId: r['clipper_user_id'] as String,
        clipPath: r['clip_path'] as String,
        status: r['status'] as String,
        note: r['note'] as String?,
        createdAt: DateTime.parse(r['created_at'] as String),
      );
}

const _campaignCols =
    'id, market_maker_user_id, title, brief, payout_per_clip_cents, '
    'max_accepted, accepted_count, escrow_remaining_cents, status, deadline, '
    'source_moment_id';

/// The public board: campaigns still taking clips, soonest deadline first.
final openCampaignsProvider =
    FutureProvider.autoDispose<List<ClipCampaign>>((ref) async {
  final rows = await Supabase.instance.client
      .from('clip_campaigns')
      .select(_campaignCols)
      .eq('status', 'open')
      .order('deadline')
      .limit(100);
  return [for (final r in rows as List) ClipCampaign.fromRow(r)];
});

/// Campaigns this user posted (any status).
final myCampaignsProvider =
    FutureProvider.autoDispose<List<ClipCampaign>>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return const [];
  final rows = await Supabase.instance.client
      .from('clip_campaigns')
      .select(_campaignCols)
      .eq('market_maker_user_id', user.id)
      .order('created_at', ascending: false);
  return [for (final r in rows as List) ClipCampaign.fromRow(r)];
});

final campaignProvider =
    FutureProvider.autoDispose.family<ClipCampaign?, String>((ref, id) async {
  final row = await Supabase.instance.client
      .from('clip_campaigns')
      .select(_campaignCols)
      .eq('id', id)
      .maybeSingle();
  return row == null ? null : ClipCampaign.fromRow(row);
});

/// Submissions the caller is allowed to see. For a Market Maker RLS returns ONLY
/// moderation-approved rows; for a clipper, their own in every state.
final campaignSubmissionsProvider = FutureProvider.autoDispose
    .family<List<ClipSubmission>, String>((ref, campaignId) async {
  final rows = await Supabase.instance.client
      .from('clip_campaign_submissions')
      .select('id, campaign_id, clipper_user_id, clip_path, status, note, created_at')
      .eq('campaign_id', campaignId)
      .order('created_at', ascending: false);
  return [for (final r in rows as List) ClipSubmission.fromRow(r)];
});

class CampaignService {
  static SupabaseClient get _client => Supabase.instance.client;

  static Future<String> create({
    required String title,
    required String brief,
    required int payoutPerClipCents,
    required int maxAccepted,
    required DateTime deadline,
    String? sourceMomentId,
  }) async {
    final res = await _client.rpc('clip_campaign_create', params: {
      'p_title': title,
      'p_brief': brief,
      'p_payout_per_clip_cents': payoutPerClipCents,
      'p_max_accepted': maxAccepted,
      'p_deadline': deadline.toUtc().toIso8601String(),
      if (sourceMomentId != null) 'p_source_moment_id': sourceMomentId,
    });
    return res as String;
  }

  /// Upload the clip + moderation sample frames into the caller's own prefix of
  /// the private clip-staging bucket, then hand off to `clip-submit`, which
  /// creates the submission AND moderates it. Nothing here can approve a clip.
  static Future<Map<String, dynamic>> submit({
    required String campaignId,
    required Uint8List clipBytes,
    required List<Uint8List> frames,
    String? note,
    int? trimStartMs,
    int? trimEndMs,
    String? simText,
  }) async {
    final uid = _client.auth.currentUser?.id;
    if (uid == null) throw StateError('Not signed in');
    final storage = _client.storage.from('clip-staging');
    final prefix = '$uid/$campaignId';

    await storage.uploadBinary(
      '$prefix/clip.mp4',
      clipBytes,
      fileOptions: const FileOptions(contentType: 'video/mp4', upsert: true),
    );
    for (var i = 0; i < frames.length; i++) {
      await storage.uploadBinary(
        '$prefix/f$i.jpg',
        frames[i],
        fileOptions: const FileOptions(contentType: 'image/jpeg', upsert: true),
      );
    }

    final res = await _client.functions.invoke('clip-submit', body: {
      'campaign_id': campaignId,
      'frame_count': frames.length,
      if (note != null && note.trim().isNotEmpty) 'note': note.trim(),
      if (trimStartMs != null) 'trim_start_ms': trimStartMs,
      if (trimEndMs != null) 'trim_end_ms': trimEndMs,
      if (simText != null) 'sim_text': simText,
    });
    return Map<String, dynamic>.from(res.data as Map);
  }

  static Future<String> accept(String submissionId) async {
    final res = await _client
        .rpc('clip_campaign_accept', params: {'p_submission': submissionId});
    return res as String;
  }

  static Future<int> cancel(String campaignId) async {
    final res = await _client
        .rpc('clip_campaign_cancel', params: {'p_campaign': campaignId});
    return (res as num).toInt();
  }

  /// A Market Maker reviews an APPROVED clip through a short-lived signed URL —
  /// the bucket is private and has no Market-Maker read policy.
  static Future<String> reviewUrl(String clipPath) async {
    return _client.storage.from('clip-staging').createSignedUrl(clipPath, 600);
  }

  static String errorMessage(Object e) {
    final s = e.toString();
    if (s.contains('KYC verification and a linked social')) {
      return 'Posting a campaign needs identity verification and a linked social profile.';
    }
    if (s.contains('your own verified post')) {
      return 'You can only tether a campaign to a post you own.';
    }
    if (s.contains('not approved by moderation')) {
      return 'That clip has not cleared moderation yet.';
    }
    if (s.contains('verify their identity')) {
      return 'This clipper needs to verify their identity before they can be paid.';
    }
    if (s.contains('maximum of')) return 'This campaign has accepted all its clips.';
    if (s.contains('escrow is exhausted')) return 'This campaign has no budget left.';
    if (s.contains('deadline has passed') || s.contains('not open')) {
      return 'This campaign is closed.';
    }
    if (s.contains('own campaign')) return 'You cannot submit to your own campaign.';
    return 'Something went wrong. Please try again.';
  }
}
