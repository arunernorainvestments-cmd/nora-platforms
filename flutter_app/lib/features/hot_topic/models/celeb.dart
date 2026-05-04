// Models for Hot Topic feature.
// Celebrities here are public figures with no NORA platform_metrics/scores.

class Celeb {
  final String id;
  final String name;
  final String? category;
  final String? imageUrl;
  final bool active;

  const Celeb({
    required this.id,
    required this.name,
    this.category,
    this.imageUrl,
    this.active = true,
  });

  factory Celeb.fromJson(Map<String, dynamic> json) => Celeb(
        id: json['id'] as String,
        name: json['name'] as String,
        category: json['category'] as String?,
        imageUrl: json['image_url'] as String?,
        active: json['active'] as bool? ?? true,
      );
}

class CelebWeeklyScore {
  final String id;
  final String weekId;
  final String celebId;
  final String celebName;
  final String? celebCategory;
  final String? celebImageUrl;
  final int points;
  final int? rank;
  final int storyVolume;
  final int lastDelta;
  final String? lastTier;
  final String? reasonText;
  final DateTime? updatedAt;

  const CelebWeeklyScore({
    required this.id,
    required this.weekId,
    required this.celebId,
    required this.celebName,
    this.celebCategory,
    this.celebImageUrl,
    required this.points,
    this.rank,
    required this.storyVolume,
    required this.lastDelta,
    this.lastTier,
    this.reasonText,
    this.updatedAt,
  });

  factory CelebWeeklyScore.fromJson(Map<String, dynamic> json) {
    final celeb = json['celebs'] as Map<String, dynamic>? ?? {};
    return CelebWeeklyScore(
      id: json['id'] as String,
      weekId: json['week_id'] as String,
      celebId: json['celeb_id'] as String,
      celebName: celeb['name'] as String? ?? '',
      celebCategory: celeb['category'] as String?,
      celebImageUrl: celeb['image_url'] as String?,
      points: (json['points'] as num?)?.toInt() ?? 1000,
      rank: (json['rank'] as num?)?.toInt(),
      storyVolume: (json['story_volume'] as num?)?.toInt() ?? 0,
      lastDelta: (json['last_delta'] as num?)?.toInt() ?? 0,
      lastTier: json['last_tier'] as String?,
      reasonText: json['reason_text'] as String?,
      updatedAt: json['updated_at'] != null
          ? DateTime.tryParse(json['updated_at'] as String)
          : null,
    );
  }
}

class WeeklyBet {
  final String id;
  final String userId;
  final String weekId;
  final String betCategory;
  final String? weeklyBetType;
  final String? simpleDirection;
  final String? celebId;
  final String? scoringWindow;
  final int tokensWagered;
  final String status;
  final int? payout;
  final DateTime placedAt;

  const WeeklyBet({
    required this.id,
    required this.userId,
    required this.weekId,
    required this.betCategory,
    this.weeklyBetType,
    this.simpleDirection,
    this.celebId,
    this.scoringWindow,
    required this.tokensWagered,
    required this.status,
    this.payout,
    required this.placedAt,
  });

  factory WeeklyBet.fromJson(Map<String, dynamic> json) => WeeklyBet(
        id: json['id'] as String,
        userId: json['user_id'] as String,
        weekId: json['week_id'] as String,
        betCategory: json['bet_category'] as String,
        weeklyBetType: json['weekly_bet_type'] as String?,
        simpleDirection: json['simple_direction'] as String?,
        celebId: json['celeb_id'] as String?,
        scoringWindow: json['scoring_window'] as String?,
        tokensWagered: (json['tokens_wagered'] as num).toInt(),
        status: json['status'] as String? ?? 'pending',
        payout: (json['payout'] as num?)?.toInt(),
        placedAt: DateTime.parse(json['placed_at'] as String),
      );
}
