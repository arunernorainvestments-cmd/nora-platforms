import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../models/profile_search_result.dart';

final searchProfilesProvider = FutureProvider.autoDispose
    .family<List<ProfileSearchResult>, String>((ref, query) async {
  final data = await Supabase.instance.client
      .from('profiles')
      .select('username, category_1, subcategory')
      .ilike('username', '%$query%')
      .limit(10);
  return (data as List)
      .map((e) => ProfileSearchResult.fromJson(e as Map<String, dynamic>))
      .toList();
});
