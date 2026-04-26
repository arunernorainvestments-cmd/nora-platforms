class ProfileSearchResult {
  final String username;
  final String? category1;
  final String? subcategory;

  const ProfileSearchResult({
    required this.username,
    this.category1,
    this.subcategory,
  });

  factory ProfileSearchResult.fromJson(Map<String, dynamic> json) =>
      ProfileSearchResult(
        username: json['username'] as String,
        category1: json['category_1'] as String?,
        subcategory: json['subcategory'] as String?,
      );
}
