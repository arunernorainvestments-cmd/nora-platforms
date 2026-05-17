import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/profile_search_result.dart';

// Combined search: celebrities + app users, run in parallel.
final searchAllProvider =
    FutureProvider.family.autoDispose<List<SearchResult>, String>((ref, query) async {
  final client = Supabase.instance.client;

  final celebsFuture = client
      .from('celebs')
      .select('id, name, category')
      .ilike('name', '%$query%')
      .eq('active', true)
      .limit(8);

  final usersFuture = client
      .from('profiles')
      .select('username, category_1, subcategory')
      .ilike('username', '%$query%')
      .not('username', 'is', null)
      .limit(10);

  final results = await Future.wait([celebsFuture, usersFuture]);

  final celebs = (results[0] as List)
      .map((r) => SearchResult.fromCeleb(r as Map<String, dynamic>))
      .toList();
  final users = (results[1] as List)
      .map((r) => SearchResult.fromUser(r as Map<String, dynamic>))
      .toList();

  // Celebrities first, then app users.
  return [...celebs, ...users];
});

// Kept for any existing references.
final searchProfilesProvider =
    FutureProvider.autoDispose.family<List<ProfileSearchResult>, String>((ref, query) async {
  final data = await Supabase.instance.client
      .from('profiles')
      .select('username, category_1, subcategory')
      .ilike('username', '%$query%')
      .limit(10);
  return (data as List)
      .map((e) => ProfileSearchResult.fromJson(e as Map<String, dynamic>))
      .toList();
});
