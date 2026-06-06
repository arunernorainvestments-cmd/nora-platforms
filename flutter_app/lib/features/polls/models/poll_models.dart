class WeeklyPoll {
  final String id;
  final String title;
  final String? description;
  final String status;
  final DateTime opensAt;
  final DateTime closesAt;

  const WeeklyPoll({
    required this.id,
    required this.title,
    this.description,
    required this.status,
    required this.opensAt,
    required this.closesAt,
  });

  bool get isOpen => status == 'open' && closesAt.isAfter(DateTime.now());

  factory WeeklyPoll.fromJson(Map<String, dynamic> json) => WeeklyPoll(
        id: json['id'] as String,
        title: json['title'] as String,
        description: json['description'] as String?,
        status: json['status'] as String,
        opensAt: DateTime.parse(json['opens_at'] as String).toLocal(),
        closesAt: DateTime.parse(json['closes_at'] as String).toLocal(),
      );
}

class PollOption {
  final String id;
  final String pollId;
  final String? creatorId;
  final String displayName;
  final String? imageUrl;
  final String? archetype;
  final double weightedVoteTotal;
  final int rawVoteCount;
  final int? currentRank;

  const PollOption({
    required this.id,
    required this.pollId,
    this.creatorId,
    required this.displayName,
    this.imageUrl,
    this.archetype,
    required this.weightedVoteTotal,
    required this.rawVoteCount,
    this.currentRank,
  });

  factory PollOption.fromJson(Map<String, dynamic> json) => PollOption(
        id: json['id'] as String,
        pollId: json['poll_id'] as String,
        creatorId: json['creator_id'] as String?,
        displayName: json['display_name'] as String,
        imageUrl: json['image_url'] as String?,
        archetype: json['archetype'] as String?,
        weightedVoteTotal:
            (json['weighted_vote_total'] as num?)?.toDouble() ?? 0,
        rawVoteCount: (json['raw_vote_count'] as num?)?.toInt() ?? 0,
        currentRank: (json['current_rank'] as num?)?.toInt(),
      );
}
