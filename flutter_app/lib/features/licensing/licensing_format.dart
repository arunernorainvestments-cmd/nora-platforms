import 'package:flutter/material.dart';
import '../../core/theme/app_theme.dart';

/// Shared formatting helpers for the Licensing Marketplace screens.
class LicensingFormat {
  LicensingFormat._();

  /// Human-readable category labels (DB stores snake_case enums).
  static const Map<String, String> categoryLabels = {
    'musician': 'Musician',
    'athlete': 'Athlete',
    'actor': 'Actor',
    'comedian': 'Comedian',
    'politician': 'Politician',
    'entrepreneur': 'Entrepreneur',
    'influencer': 'Influencer',
    'content_creator': 'Content Creator',
    'artist': 'Artist',
    'scientist': 'Scientist',
    'other': 'Other',
  };

  static String categoryLabel(String? raw) =>
      categoryLabels[raw] ?? (raw ?? 'Other');

  /// All category keys in display order (for filter chips & create form).
  static const List<String> categoryKeys = [
    'musician', 'athlete', 'actor', 'comedian', 'politician', 'entrepreneur',
    'influencer', 'content_creator', 'artist', 'scientist', 'other',
  ];

  /// `1999` cents → `$19.99`; `0` → `Free`.
  static String price(num? cents) {
    final c = (cents ?? 0).toInt();
    if (c == 0) return 'Free';
    final dollars = c / 100;
    return '\$${dollars.toStringAsFixed(dollars == dollars.roundToDouble() ? 0 : 2)}';
  }

  static Color statusColor(String? status) {
    switch (status) {
      case 'active':
        return AppTheme.success;
      case 'revoked':
      case 'suspended':
        return AppTheme.danger;
      case 'expired':
      case 'transferred':
        return AppTheme.textSecondary;
      default:
        return AppTheme.textSecondary;
    }
  }

  static String statusLabel(String? status) {
    if (status == null || status.isEmpty) return 'Unknown';
    return status[0].toUpperCase() + status.substring(1);
  }

  /// Human-readable permitted purposes from a template row (mirrors the
  /// sync_lkn_public_registry() DB trigger so the UI matches the public record).
  static List<String> permittedPurposes(Map<String, dynamic> t) {
    final out = <String>[];
    if (t['purpose_ai_generated_content'] == true) out.add('AI-generated content');
    if (t['purpose_ai_voice_cloning'] == true) out.add('AI voice cloning');
    if (t['purpose_ai_image_generation'] == true) out.add('AI image generation');
    if (t['purpose_ai_model_training'] == true) out.add('AI model training');
    if (t['purpose_commercial_advertising'] == true) out.add('Commercial advertising');
    if (t['purpose_entertainment_film'] == true) out.add('Film production');
    if (t['purpose_entertainment_tv'] == true) out.add('Television');
    if (t['purpose_entertainment_game'] == true) out.add('Video games & apps');
    if (t['purpose_music'] == true) out.add('Music & music video');
    if (t['purpose_social_media'] == true) out.add('Social media content');
    if (t['purpose_merchandise'] == true) out.add('Merchandise');
    if (t['purpose_nft_digital_asset'] == true) out.add('NFT / digital asset');
    if (t['purpose_editorial_news'] == true) out.add('Editorial & news');
    return out;
  }

  /// Human-readable content restrictions from a template row.
  static List<String> restrictions(Map<String, dynamic> t) {
    final out = <String>[];
    if (t['restrict_profanity'] == true) out.add('No profanity');
    if (t['restrict_adult_content'] == true) out.add('No adult content');
    if (t['restrict_political_content'] == true) out.add('No political content');
    if (t['restrict_religious_content'] == true) out.add('No religious content');
    if (t['restrict_violence'] == true) out.add('No depictions of violence');
    if (t['restrict_substance_use'] == true) out.add('No substance use');
    if (t['restrict_competitor_brands'] == true) out.add('No competitor brands');
    if (t['restrict_illegal_activity'] == true) out.add('No illegal activity');
    return out;
  }

  static String territoryLabel(String? t) {
    switch (t) {
      case 'worldwide':
        return 'Worldwide';
      case 'us_only':
        return 'United States only';
      case 'eu_only':
        return 'European Union only';
      case 'specific':
        return 'Specific countries';
      default:
        return t ?? '—';
    }
  }

  static String durationLabel(Map<String, dynamic> t) {
    switch (t['duration_type']) {
      case 'perpetual':
        return 'Perpetual';
      case 'project_specific':
        return 'Project-specific';
      case 'fixed':
        final exp = t['expires_at'];
        final d = exp == null ? null : DateTime.tryParse(exp.toString());
        return d == null
            ? 'Fixed term'
            : 'Until ${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
      default:
        return '—';
    }
  }

  /// Maps the lkn_listings `covers_*` booleans to display labels.
  static List<String> coveredRights(Map<String, dynamic> listing) {
    final out = <String>[];
    if (listing['covers_name'] == true) out.add('Name');
    if (listing['covers_image'] == true) out.add('Image');
    if (listing['covers_voice'] == true) out.add('Voice');
    if (listing['covers_signature'] == true) out.add('Signature');
    if (listing['covers_persona'] == true) out.add('Persona');
    return out;
  }
}
