class WaitlistUser {
  final String email;
  final String referralToken;
  final int referralCount;
  final String createdAt;

  const WaitlistUser({
    required this.email,
    required this.referralToken,
    required this.referralCount,
    required this.createdAt,
  });

  factory WaitlistUser.fromJson(Map<String, dynamic> json) {
    return WaitlistUser(
      email: json['email'] as String,
      referralToken: json['referral_token'] as String,
      referralCount: (json['referral_count'] as num).toInt(),
      createdAt: json['created_at'] as String,
    );
  }
}

class WaitlistResponse {
  final WaitlistUser user;
  final int queuePosition;
  final int totalCount;
  final String referralLink;
  final bool isNewUser;

  const WaitlistResponse({
    required this.user,
    required this.queuePosition,
    required this.totalCount,
    required this.referralLink,
    required this.isNewUser,
  });

  factory WaitlistResponse.fromJson(Map<String, dynamic> json) {
    return WaitlistResponse(
      user: WaitlistUser.fromJson(json['user'] as Map<String, dynamic>),
      queuePosition: (json['queue_position'] as num).toInt(),
      totalCount: (json['total_count'] as num).toInt(),
      referralLink: json['referral_link'] as String,
      isNewUser: json['is_new_user'] as bool? ?? true,
    );
  }
}

// ── State ─────────────────────────────────────────────────────────────────────

sealed class WaitlistState {}

class WaitlistLoading extends WaitlistState {}

class WaitlistAnonymous extends WaitlistState {}

class WaitlistJoined extends WaitlistState {
  final WaitlistResponse response;
  WaitlistJoined(this.response);
}

class WaitlistReturning extends WaitlistState {
  final WaitlistResponse response;
  WaitlistReturning(this.response);
}
