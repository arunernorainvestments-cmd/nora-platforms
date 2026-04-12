class ProfileSearchResult {
  final String username;
  final String? category1;
  final String? category2;

  const ProfileSearchResult({
    required this.username,
    this.category1,
    this.category2,
  });

  factory ProfileSearchResult.fromJson(Map<String, dynamic> json) =>
      ProfileSearchResult(
        username: json['username'] as String,
        category1: json['category_1'] as String?,
        category2: json['category_2'] as String?,
      );
}
