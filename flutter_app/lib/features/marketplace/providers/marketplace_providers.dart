import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

// Active likeness offerings (primary market — cards being minted for first time)
final likenessOfferingsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final data = await Supabase.instance.client
      .from('likeness_offerings')
      .select('*, profiles!creator_id(username, display_name, avatar_url)')
      .eq('status', 'active')
      .order('listed_at', ascending: false);
  return List<Map<String, dynamic>>.from(data as List);
});

// Secondary card market listings
final cardListingsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final data = await Supabase.instance.client
      .from('card_marketplace_listings')
      .select(
        'id, asking_price_usd_cents, created_at, '
        'likeness_cards!card_id(card_number, rarity, creator_id, offering_id), '
        'likeness_offerings!offering_id(character_name, character_image_url, archetype)',
      )
      .eq('status', 'active')
      .order('created_at', ascending: false)
      .limit(50);
  return List<Map<String, dynamic>>.from(data as List);
});

// Cards owned by the current user
final myLikenessCardsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return [];
  final data = await Supabase.instance.client
      .from('likeness_cards')
      .select(
        'id, card_number, rarity, is_active, minted_at, offering_id, '
        'likeness_offerings!offering_id(character_name, character_image_url, archetype)',
      )
      .eq('current_owner_id', userId)
      .eq('is_active', true)
      .order('minted_at', ascending: false);
  return List<Map<String, dynamic>>.from(data as List);
});

// Single offering detail
final offeringDetailProvider =
    FutureProvider.family.autoDispose<Map<String, dynamic>?, String>(
        (ref, offeringId) async {
  final data = await Supabase.instance.client
      .from('likeness_offerings')
      .select('*, profiles!creator_id(id, username, display_name, avatar_url)')
      .eq('id', offeringId)
      .maybeSingle();
  return data;
});

// Single card detail (with transfer history)
final cardDetailProvider =
    FutureProvider.family.autoDispose<Map<String, dynamic>?, String>(
        (ref, cardId) async {
  final data = await Supabase.instance.client
      .from('likeness_cards')
      .select(
        'id, card_number, rarity, creator_id, current_owner_id, minted_at, '
        'likeness_offerings!offering_id(character_name, character_image_url, archetype, creator_id)',
      )
      .eq('id', cardId)
      .maybeSingle();
  return data;
});

// Card transfer history (ownership log)
final cardTransfersProvider =
    FutureProvider.family.autoDispose<List<Map<String, dynamic>>, String>(
        (ref, cardId) async {
  final data = await Supabase.instance.client
      .from('likeness_card_transfers')
      .select(
        'id, transfer_type, usd_cents_paid, created_at, '
        'to_profile:profiles!to_user_id(username)',
      )
      .eq('card_id', cardId)
      .order('created_at', ascending: false)
      .limit(20);
  return List<Map<String, dynamic>>.from(data as List);
});

// Active chit marketplace listings
final chitListingsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final data = await Supabase.instance.client
      .from('chit_marketplace_listings')
      .select('*, battle_chit_definitions!chit_definition_id(*)')
      .eq('status', 'active')
      .order('created_at', ascending: false)
      .limit(50);
  return List<Map<String, dynamic>>.from(data as List);
});

// All chit definitions (for "Earn" tab display)
final chitDefinitionsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final data = await Supabase.instance.client
      .from('battle_chit_definitions')
      .select()
      .eq('is_active', true)
      .order('rarity');
  return List<Map<String, dynamic>>.from(data as List);
});

// Current user's chit inventory
final myChitsProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
  final userId = Supabase.instance.client.auth.currentUser?.id;
  if (userId == null) return [];
  final data = await Supabase.instance.client
      .from('user_battle_chits')
      .select('*, battle_chit_definitions!chit_definition_id(*)')
      .eq('user_id', userId)
      .gt('quantity', 0)
      .order('acquired_at', ascending: false);
  return List<Map<String, dynamic>>.from(data as List);
});
