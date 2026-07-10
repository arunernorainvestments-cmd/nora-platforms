import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../licensing_format.dart';
import '../../../core/widgets/n_back_button.dart';

/// Multi-step form for licensors to create a marketplace listing.
/// On submit: lkn-create-listing → lkn-submit-template per tier (the toggle
/// parameters are shared across the listing's tiers) → submit_for_review.
class CreateListingScreen extends ConsumerStatefulWidget {
  const CreateListingScreen({super.key});

  @override
  ConsumerState<CreateListingScreen> createState() =>
      _CreateListingScreenState();
}

class _CreateListingScreenState extends ConsumerState<CreateListingScreen> {
  int _step = 0;
  bool _submitting = false;

  // ── Step 1: basics ──
  final _title = TextEditingController();
  final _description = TextEditingController();
  final _displayName = TextEditingController();
  final _imageUrl = TextEditingController();
  String _category = 'musician';
  bool _coversName = true;
  bool _coversImage = true;
  bool _coversVoice = false;
  bool _coversSignature = false;
  bool _coversPersona = false;

  // ── Step 2: tiers ──
  final List<_TierDraft> _tiers = [_TierDraft()];

  // ── Step 3: toggle parameters (shared across tiers) ──
  final _params = _defaultParams();

  // ── Step 4: addendum ──
  final _addendum = TextEditingController();

  static Map<String, dynamic> _defaultParams() => {
        'duration_type': 'perpetual',
        'expires_at': null, // DateTime
        'territory': 'worldwide',
        // permitted uses (default off; editorial baseline true at DB level)
        'purpose_ai_generated_content': false,
        'purpose_ai_voice_cloning': false,
        'purpose_ai_image_generation': false,
        'purpose_ai_model_training': false,
        'purpose_commercial_advertising': false,
        'purpose_entertainment_film': false,
        'purpose_entertainment_tv': false,
        'purpose_entertainment_game': false,
        'purpose_music': false,
        'purpose_social_media': false,
        'purpose_merchandise': false,
        'purpose_nft_digital_asset': false,
        // restrictions (default on = restrictive)
        'restrict_profanity': true,
        'restrict_adult_content': true,
        'restrict_political_content': false,
        'restrict_religious_content': false,
        'restrict_violence': true,
        'restrict_substance_use': true,
        'restrict_competitor_brands': false,
        // AI controls
        'ai_generated_must_be_labeled': true,
        // sublicensing & approval
        'sublicensing_allowed': false,
        'approval_required_before_publish': false,
        // revenue
        'revenue_share_pct': 0.0,
        // revocation
        'revocation_type': 'for_cause',
      };

  static const List<String> _purposeKeys = [
    'purpose_ai_generated_content',
    'purpose_ai_voice_cloning',
    'purpose_ai_image_generation',
    'purpose_ai_model_training',
    'purpose_commercial_advertising',
    'purpose_entertainment_film',
    'purpose_entertainment_tv',
    'purpose_entertainment_game',
    'purpose_music',
    'purpose_social_media',
    'purpose_merchandise',
    'purpose_nft_digital_asset',
  ];

  static const Map<String, String> _purposeLabels = {
    'purpose_ai_generated_content': 'AI-generated content',
    'purpose_ai_voice_cloning': 'AI voice cloning',
    'purpose_ai_image_generation': 'AI image generation',
    'purpose_ai_model_training': 'AI model training datasets',
    'purpose_commercial_advertising': 'Commercial advertising',
    'purpose_entertainment_film': 'Film production',
    'purpose_entertainment_tv': 'Television',
    'purpose_entertainment_game': 'Video games & apps',
    'purpose_music': 'Music & music video',
    'purpose_social_media': 'Social media content',
    'purpose_merchandise': 'Merchandise',
    'purpose_nft_digital_asset': 'NFT / digital asset',
  };

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    _displayName.dispose();
    _imageUrl.dispose();
    _addendum.dispose();
    for (final t in _tiers) {
      t.dispose();
    }
    super.dispose();
  }

  // ── Validation per step ──
  String? _validateStep() {
    switch (_step) {
      case 0:
        if (_title.text.trim().isEmpty) return 'Enter a listing title.';
        if (_displayName.text.trim().isEmpty) {
          return 'Enter the display name shown in search.';
        }
        if (!(_coversName ||
            _coversImage ||
            _coversVoice ||
            _coversSignature ||
            _coversPersona)) {
          return 'Select at least one right the license covers.';
        }
        return null;
      case 1:
        if (_tiers.isEmpty) return 'Add at least one tier.';
        for (final t in _tiers) {
          if (t.name.text.trim().isEmpty) return 'Every tier needs a name.';
          final price = double.tryParse(t.price.text.trim());
          if (price == null || price < 0) {
            return 'Every tier needs a valid price (use 0 for free).';
          }
        }
        return null;
      case 2:
        if (_params['duration_type'] == 'fixed' &&
            _params['expires_at'] == null) {
          return 'Pick an expiration date for a fixed-term license.';
        }
        return null;
      default:
        return null;
    }
  }

  void _next() {
    final err = _validateStep();
    if (err != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(err)));
      return;
    }
    if (_step < 4) {
      setState(() => _step++);
    } else {
      _submit();
    }
  }

  void _back() {
    if (_step > 0) setState(() => _step--);
  }

  Map<String, dynamic> _buildParamsPayload() {
    final p = <String, dynamic>{};
    p['duration_type'] = _params['duration_type'];
    if (_params['duration_type'] == 'fixed' &&
        _params['expires_at'] is DateTime) {
      p['expires_at'] = (_params['expires_at'] as DateTime).toIso8601String();
    }
    p['territory'] = _params['territory'];
    for (final k in [
      ..._purposeKeys,
      'restrict_profanity',
      'restrict_adult_content',
      'restrict_political_content',
      'restrict_religious_content',
      'restrict_violence',
      'restrict_substance_use',
      'restrict_competitor_brands',
      'ai_generated_must_be_labeled',
      'sublicensing_allowed',
      'approval_required_before_publish',
    ]) {
      p[k] = _params[k] == true;
    }
    p['revocation_type'] = _params['revocation_type'];
    final pct = (_params['revenue_share_pct'] as num?)?.toDouble() ?? 0.0;
    if (pct > 0) {
      p['revenue_share_pct'] = pct;
      p['revenue_share_applies_to'] = 'gross_revenue';
    }
    if (_addendum.text.trim().isNotEmpty) {
      p['addendum_description'] = _addendum.text.trim();
    }
    return p;
  }

  Future<void> _submit() async {
    if (_submitting) return;
    setState(() => _submitting = true);
    try {
      final client = Supabase.instance.client;
      final tierPayload = _tiers.map((t) {
        final dollars = double.tryParse(t.price.text.trim()) ?? 0;
        return {
          'tier_name': t.name.text.trim(),
          'tier_description': t.description.text.trim().isEmpty
              ? null
              : t.description.text.trim(),
          'price_usd_cents': (dollars * 100).round(),
          'is_exclusive': t.isExclusive,
          'max_licenses': t.isExclusive
              ? (int.tryParse(t.maxLicenses.text.trim()))
              : null,
        };
      }).toList();

      final createResp = await client.functions.invoke(
        'lkn-create-listing',
        body: {
          'listing_title': _title.text.trim(),
          'listing_description': _description.text.trim().isEmpty
              ? null
              : _description.text.trim(),
          'licensor_display_name': _displayName.text.trim(),
          'licensor_image_url':
              _imageUrl.text.trim().isEmpty ? null : _imageUrl.text.trim(),
          'category': _category,
          'covers_name': _coversName,
          'covers_image': _coversImage,
          'covers_voice': _coversVoice,
          'covers_signature': _coversSignature,
          'covers_persona': _coversPersona,
          'tiers': tierPayload,
        },
      );
      final createData = createResp.data as Map<String, dynamic>?;
      final listingId = createData?['listing_id'] as String?;
      final createdTiers =
          (createData?['tiers'] as List?)?.cast<Map<String, dynamic>>() ??
              const [];
      if (listingId == null || createdTiers.isEmpty) {
        throw Exception(createData?['error'] ?? 'Could not create listing');
      }

      final params = _buildParamsPayload();
      for (var i = 0; i < createdTiers.length; i++) {
        final isLast = i == createdTiers.length - 1;
        final tplResp = await client.functions.invoke(
          'lkn-submit-template',
          body: {'tier_id': createdTiers[i]['id'], 'params': params},
          queryParameters: isLast ? {'submit_for_review': 'true'} : null,
        );
        final tplData = tplResp.data as Map<String, dynamic>?;
        if (tplData?['error'] != null) throw Exception(tplData!['error']);
      }

      if (!mounted) return;
      _showSubmitted();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Could not submit listing: $e')),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  void _showSubmitted() {
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Row(children: [
          Icon(Icons.check_circle, color: AppTheme.success),
          SizedBox(width: 10),
          Text('Submitted for review',
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 18)),
        ]),
        content: const Text(
          'Your listing has been submitted for N.O.R.A. review. Once approved '
          'it will appear in the marketplace.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          ElevatedButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              context.go('/licenses');
            },
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    const titles = [
      'Basic info',
      'License tiers',
      'Parameters',
      'Addendum',
      'Review',
    ];
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: const NBackButton(fallback: '/licenses'),
        backgroundColor: AppTheme.surface,
        title: Text('Create Listing · ${titles[_step]}',
            style: const TextStyle(color: AppTheme.textPrimary, fontSize: 16)),
        iconTheme: const IconThemeData(color: AppTheme.textPrimary),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 680),
          child: Column(
            children: [
              _StepBar(step: _step, total: titles.length),
              Expanded(
                child: ListView(
                  padding: const EdgeInsets.all(20),
                  children: [_stepBody()],
                ),
              ),
              _navBar(),
            ],
          ),
        ),
      ),
    );
  }

  Widget _stepBody() {
    switch (_step) {
      case 0:
        return _basicsStep();
      case 1:
        return _tiersStep();
      case 2:
        return _paramsStep();
      case 3:
        return _addendumStep();
      default:
        return _reviewStep();
    }
  }

  // ── Step 1 ──
  Widget _basicsStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _input(_title, 'Listing title',
            hint: 'e.g. Official Likeness License'),
        _input(_displayName, 'Display name (shown in search)'),
        _input(_description, 'Description', maxLines: 4),
        _input(_imageUrl, 'Image URL (optional)'),
        const SizedBox(height: 4),
        const _Label('Category'),
        DropdownButtonFormField<String>(
          initialValue: _category,
          dropdownColor: AppTheme.surface,
          style: const TextStyle(color: AppTheme.textPrimary),
          decoration: const InputDecoration(),
          items: LicensingFormat.categoryKeys
              .map((k) => DropdownMenuItem(
                  value: k, child: Text(LicensingFormat.categoryLabel(k))))
              .toList(),
          onChanged: (v) => setState(() => _category = v ?? 'musician'),
        ),
        const SizedBox(height: 16),
        const _Label('What does this license cover?'),
        _coverCheck('Name', _coversName, (v) => _coversName = v),
        _coverCheck('Image / likeness', _coversImage, (v) => _coversImage = v),
        _coverCheck('Voice', _coversVoice, (v) => _coversVoice = v),
        _coverCheck('Signature', _coversSignature, (v) => _coversSignature = v),
        _coverCheck('Persona / personality', _coversPersona,
            (v) => _coversPersona = v),
      ],
    );
  }

  Widget _coverCheck(String label, bool value, ValueChanged<bool> onChanged) {
    return CheckboxListTile(
      value: value,
      onChanged: (v) => setState(() => onChanged(v ?? false)),
      controlAffinity: ListTileControlAffinity.leading,
      contentPadding: EdgeInsets.zero,
      activeColor: AppTheme.primary,
      dense: true,
      title: Text(label,
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14)),
    );
  }

  // ── Step 2 ──
  Widget _tiersStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Create 1–3 priced tiers.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 14)),
        const SizedBox(height: 12),
        ...List.generate(_tiers.length, (i) => _tierEditor(i)),
        if (_tiers.length < 3)
          TextButton.icon(
            onPressed: () => setState(() => _tiers.add(_TierDraft())),
            icon: const Icon(Icons.add),
            label: const Text('Add tier'),
          ),
      ],
    );
  }

  Widget _tierEditor(int i) {
    final t = _tiers[i];
    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text('Tier ${i + 1}',
                  style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontWeight: FontWeight.bold)),
              const Spacer(),
              if (_tiers.length > 1)
                IconButton(
                  icon: const Icon(Icons.delete_outline,
                      color: AppTheme.danger, size: 20),
                  onPressed: () => setState(() {
                    _tiers.removeAt(i).dispose();
                  }),
                ),
            ],
          ),
          _input(t.name, 'Tier name', hint: 'e.g. Commercial'),
          _input(t.description, 'Description (optional)'),
          _input(t.price, 'Price (USD)',
              hint: '0 for free', keyboard: TextInputType.number),
          SwitchListTile(
            value: t.isExclusive,
            onChanged: (v) => setState(() => t.isExclusive = v),
            contentPadding: EdgeInsets.zero,
            activeThumbColor: AppTheme.secondary,
            dense: true,
            title: const Text('Exclusive / limited supply',
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 14)),
          ),
          if (t.isExclusive)
            _input(t.maxLicenses, 'Max licenses (blank = unlimited)',
                keyboard: TextInputType.number),
        ],
      ),
    );
  }

  // ── Step 3: the toggle UI ──
  Widget _paramsStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'These parameters apply to every tier in this listing. Defaults are '
          'the most restrictive — opt in to what you allow.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
        const SizedBox(height: 16),

        _ToggleSection(title: 'Duration', children: [
          _segmented(
            'duration_type',
            const {
              'perpetual': 'Perpetual',
              'fixed': 'Fixed term',
              'project_specific': 'Project',
            },
          ),
          if (_params['duration_type'] == 'fixed') _expiryPicker(),
        ]),

        _ToggleSection(title: 'Territory', children: [
          _segmented(
            'territory',
            const {
              'worldwide': 'Worldwide',
              'us_only': 'US only',
              'eu_only': 'EU only',
              'specific': 'Specific',
            },
          ),
        ]),

        _ToggleSection(
          title: 'Permitted uses',
          subtitle: 'What the licensee may use the likeness for.',
          children: _purposeKeys
              .map((k) => _switch(k, _purposeLabels[k]!,
                  desc: _purposeDesc(k)))
              .toList(),
        ),

        _ToggleSection(
          title: 'Content restrictions',
          subtitle: 'On = the licensee may NOT depict this.',
          children: [
            _switch('restrict_profanity', 'No profanity'),
            _switch('restrict_adult_content', 'No adult content',
                dangerousWhenOff: true),
            _switch('restrict_violence', 'No depictions of violence'),
            _switch('restrict_substance_use', 'No substance use'),
            _switch('restrict_political_content', 'No political content'),
            _switch('restrict_religious_content', 'No religious content'),
            _switch('restrict_competitor_brands', 'No competitor brands'),
          ],
        ),

        _ToggleSection(title: 'AI controls', children: [
          _switch('ai_generated_must_be_labeled',
              'AI-generated output must be labeled'),
        ]),

        _ToggleSection(title: 'Sublicensing & approval', children: [
          _switch('sublicensing_allowed', 'Allow sublicensing'),
          _switch('approval_required_before_publish',
              'Require my approval before publish'),
        ]),

        _ToggleSection(title: 'Revenue share', children: [
          _revShareSlider(),
        ]),

        _ToggleSection(title: 'Revocation', children: [
          _segmented(
            'revocation_type',
            const {
              'for_cause': 'For cause',
              'at_will_30_days': 'At-will (30d)',
              'irrevocable': 'Irrevocable',
            },
            confirmKeyValue: const MapEntry('revocation_type', 'irrevocable'),
            confirmMessage:
                'An irrevocable license cannot be cancelled later. Continue?',
          ),
        ]),
      ],
    );
  }

  String? _purposeDesc(String k) {
    switch (k) {
      case 'purpose_ai_model_training':
        return 'Allows inclusion in AI training datasets.';
      case 'purpose_ai_voice_cloning':
        return 'Allows synthetic recreation of the voice.';
      default:
        return null;
    }
  }

  Widget _expiryPicker() {
    final dt = _params['expires_at'] as DateTime?;
    return ListTile(
      contentPadding: EdgeInsets.zero,
      title: Text(
        dt == null
            ? 'Pick expiration date'
            : 'Expires ${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}',
        style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14),
      ),
      trailing: const Icon(Icons.calendar_today,
          size: 18, color: AppTheme.primary),
      onTap: () async {
        final now = DateTime.now();
        final picked = await showDatePicker(
          context: context,
          initialDate: dt ?? now.add(const Duration(days: 365)),
          firstDate: now,
          lastDate: now.add(const Duration(days: 365 * 20)),
        );
        if (picked != null) setState(() => _params['expires_at'] = picked);
      },
    );
  }

  Widget _revShareSlider() {
    final pct = (_params['revenue_share_pct'] as num?)?.toDouble() ?? 0.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('Ongoing revenue share: ${pct.toStringAsFixed(0)}%',
            style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14)),
        Slider(
          value: pct,
          min: 0,
          max: 50,
          divisions: 50,
          activeColor: AppTheme.primary,
          label: '${pct.toStringAsFixed(0)}%',
          onChanged: (v) =>
              setState(() => _params['revenue_share_pct'] = v),
        ),
        if (pct > 0)
          const Text('Applied to gross revenue.',
              style:
                  TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
      ],
    );
  }

  // ── Step 4 ──
  Widget _addendumStep() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Optionally describe a custom addendum. (PDF upload becomes available '
          'after your listing passes review.)',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
        ),
        const SizedBox(height: 16),
        _input(_addendum, 'Addendum summary (optional)', maxLines: 5),
      ],
    );
  }

  // ── Step 5 ──
  Widget _reviewStep() {
    final purposes = _purposeKeys
        .where((k) => _params[k] == true)
        .map((k) => _purposeLabels[k]!)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _reviewCard('Listing', [
          _title.text.trim(),
          _displayName.text.trim(),
          LicensingFormat.categoryLabel(_category),
        ]),
        _reviewCard(
          'Tiers',
          _tiers
              .map((t) =>
                  '${t.name.text.trim()} — ${LicensingFormat.price((double.tryParse(t.price.text.trim()) ?? 0) * 100)}')
              .toList(),
        ),
        _reviewCard('Permitted uses',
            purposes.isEmpty ? ['Editorial & news only'] : purposes),
        _reviewCard('Duration & territory', [
          LicensingFormat.durationLabel({
            'duration_type': _params['duration_type'],
            'expires_at': (_params['expires_at'] as DateTime?)
                ?.toIso8601String(),
          }),
          LicensingFormat.territoryLabel(_params['territory'] as String?),
        ]),
        const SizedBox(height: 8),
        const Text(
          'On submit, your listing is created as a draft and sent for N.O.R.A. '
          'review before it appears publicly.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
      ],
    );
  }

  Widget _reviewCard(String title, List<String> lines) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
          const SizedBox(height: 6),
          ...lines.where((l) => l.isNotEmpty).map((l) => Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Text(l,
                    style: const TextStyle(
                        color: AppTheme.textPrimary, fontSize: 14)),
              )),
        ],
      ),
    );
  }

  // ── Shared widgets ──
  Widget _navBar() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        border: Border(top: BorderSide(color: AppTheme.cardBorder)),
      ),
      child: Row(
        children: [
          if (_step > 0)
            Expanded(
              child: OutlinedButton(
                onPressed: _submitting ? null : _back,
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textSecondary,
                  side: const BorderSide(color: AppTheme.cardBorder),
                ),
                child: const Text('Back'),
              ),
            ),
          if (_step > 0) const SizedBox(width: 12),
          Expanded(
            flex: 2,
            child: ElevatedButton(
              onPressed: _submitting ? null : _next,
              child: _submitting
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : Text(_step == 4 ? 'Submit for review' : 'Next'),
            ),
          ),
        ],
      ),
    );
  }

  Widget _input(
    TextEditingController controller,
    String label, {
    String? hint,
    int maxLines = 1,
    TextInputType? keyboard,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        maxLines: maxLines,
        keyboardType: keyboard,
        inputFormatters: keyboard == TextInputType.number
            ? [FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))]
            : null,
        style: const TextStyle(color: AppTheme.textPrimary),
        decoration: InputDecoration(labelText: label, hintText: hint),
      ),
    );
  }

  Widget _switch(String key, String label,
      {String? desc, bool dangerousWhenOff = false}) {
    return SwitchListTile(
      value: _params[key] == true,
      onChanged: (v) async {
        if (dangerousWhenOff && _params[key] == true && v == false) {
          final ok = await _confirm(
              'Turning this off permits adult content depictions. Continue?');
          if (!ok) return;
        }
        setState(() => _params[key] = v);
      },
      contentPadding: EdgeInsets.zero,
      activeThumbColor: AppTheme.primary,
      dense: true,
      title: Text(label,
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14)),
      subtitle: desc == null
          ? null
          : Text(desc,
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 12)),
    );
  }

  Widget _segmented(
    String key,
    Map<String, String> options, {
    MapEntry<String, String>? confirmKeyValue,
    String? confirmMessage,
  }) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: options.entries.map((e) {
        final selected = _params[key] == e.key;
        return ChoiceChip(
          label: Text(e.value),
          selected: selected,
          backgroundColor: AppTheme.background,
          selectedColor: AppTheme.primary.withValues(alpha: 0.25),
          side: BorderSide(
              color: selected ? AppTheme.primary : AppTheme.cardBorder),
          labelStyle: TextStyle(
            color: selected ? AppTheme.primary : AppTheme.textSecondary,
            fontWeight: FontWeight.w600,
            fontSize: 13,
          ),
          onSelected: (_) async {
            if (confirmKeyValue != null &&
                confirmKeyValue.key == key &&
                e.key == confirmKeyValue.value) {
              final ok = await _confirm(confirmMessage ?? 'Are you sure?');
              if (!ok) return;
            }
            setState(() => _params[key] = e.key);
          },
        );
      }).toList(),
    );
  }

  Future<bool> _confirm(String message) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Please confirm',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 18)),
        content: Text(message,
            style: const TextStyle(color: AppTheme.textSecondary)),
        actions: [
          TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style:
                ElevatedButton.styleFrom(backgroundColor: AppTheme.danger),
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
    return result ?? false;
  }
}

// ─── Tier draft (mutable, controller-backed) ──────────────────────────────────
class _TierDraft {
  final name = TextEditingController();
  final description = TextEditingController();
  final price = TextEditingController();
  final maxLicenses = TextEditingController();
  bool isExclusive = false;

  void dispose() {
    name.dispose();
    description.dispose();
    price.dispose();
    maxLicenses.dispose();
  }
}

// ─── Small presentational helpers ─────────────────────────────────────────────
class _StepBar extends StatelessWidget {
  final int step;
  final int total;
  const _StepBar({required this.step, required this.total});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      child: Row(
        children: List.generate(total, (i) {
          final done = i <= step;
          return Expanded(
            child: Container(
              height: 4,
              margin: EdgeInsets.only(right: i == total - 1 ? 0 : 6),
              decoration: BoxDecoration(
                color: done ? AppTheme.primary : AppTheme.cardBorder,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          );
        }),
      ),
    );
  }
}

class _ToggleSection extends StatelessWidget {
  final String title;
  final String? subtitle;
  final List<Widget> children;
  const _ToggleSection({
    required this.title,
    this.subtitle,
    required this.children,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
          if (subtitle != null) ...[
            const SizedBox(height: 2),
            Text(subtitle!,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 12)),
          ],
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(text,
          style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600)),
    );
  }
}
