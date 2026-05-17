enum SearchResultKind { user, celebrity }

class SearchResult {
  final SearchResultKind kind;
  final String id;         // username for users, UUID for celebs
  final String name;       // display name (no @ prefix)
  final String? category;
  final String? subcategory;

  const SearchResult({
    required this.kind,
    required this.id,
    required this.name,
    this.category,
    this.subcategory,
  });

  factory SearchResult.fromUser(Map<String, dynamic> json) => SearchResult(
        kind: SearchResultKind.user,
        id: json['username'] as String,
        name: json['username'] as String,
        category: json['category_1'] as String?,
        subcategory: json['subcategory'] as String?,
      );

  factory SearchResult.fromCeleb(Map<String, dynamic> json) => SearchResult(
        kind: SearchResultKind.celebrity,
        id: json['id'] as String,
        name: json['name'] as String,
        category: json['category'] as String?,
      );
}

// Keep for backwards-compat — existing usages of ProfileSearchResult still compile.
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
