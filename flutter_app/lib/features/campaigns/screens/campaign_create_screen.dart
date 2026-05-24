import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/campaigns_providers.dart';

class CampaignCreateScreen extends ConsumerStatefulWidget {
  const CampaignCreateScreen({super.key});

  @override
  ConsumerState<CampaignCreateScreen> createState() =>
      _CampaignCreateScreenState();
}

class _CampaignCreateScreenState extends ConsumerState<CampaignCreateScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _goalCtrl = TextEditingController();
  final _royaltyCtrl = TextEditingController();
  final _minInvestCtrl = TextEditingController(text: '10');
  final _termCtrl = TextEditingController();

  String _category = 'album';
  bool _saving = false;

  static const _categories = [
    'album', 'ep', 'single', 'film', 'documentary', 'podcast',
    'software', 'game', 'tour', 'merchandise', 'other',
  ];

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _goalCtrl.dispose();
    _royaltyCtrl.dispose();
    _minInvestCtrl.dispose();
    _termCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    try {
      final userId = Supabase.instance.client.auth.currentUser?.id;
      if (userId == null) throw Exception('Not logged in');

      final goalDollars = double.parse(_goalCtrl.text.replaceAll(',', ''));
      final royaltyPct = double.parse(_royaltyCtrl.text);
      final minInvestDollars =
          double.parse(_minInvestCtrl.text.replaceAll(',', ''));
      final termYears = _termCtrl.text.trim().isEmpty
          ? null
          : int.parse(_termCtrl.text.trim());

      await Supabase.instance.client.from('campaigns').insert({
        'creator_id': userId,
        'title': _titleCtrl.text.trim(),
        'description': _descCtrl.text.trim().isEmpty
            ? null
            : _descCtrl.text.trim(),
        'category': _category,
        'funding_goal_usd_cents': (goalDollars * 100).round(),
        'royalty_pct_offered': royaltyPct,
        'min_investment_usd_cents': (minInvestDollars * 100).round(),
        'royalty_term_years': termYears,
        'status': 'draft',
        'mode': 'simulated',
      });

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Campaign saved as draft'),
            backgroundColor: AppTheme.success,
          ),
        );
        ref.invalidate(myCreatedCampaignsProvider);
        context.pop();
      }
    } on PostgrestException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.message),
            backgroundColor: AppTheme.danger,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(e.toString()),
            backgroundColor: AppTheme.danger,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: const Text('Launch a Campaign'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('SIMULATION MODE',
                style: TextStyle(
                    color: AppTheme.secondary,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1)),
            const SizedBox(height: 4),
            const Text(
              'Campaigns are simulated — no real money is involved until regulatory approval.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 24),

            _Field(
              label: 'Campaign title',
              controller: _titleCtrl,
              hint: 'e.g. "Debut Album — Midnight Sessions"',
              validator: (v) =>
                  v == null || v.trim().isEmpty ? 'Required' : null,
            ),
            const SizedBox(height: 16),

            _Field(
              label: 'Description (optional)',
              controller: _descCtrl,
              hint: 'What are you making? What will backers get?',
              maxLines: 4,
            ),
            const SizedBox(height: 16),

            // Category picker
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Category',
                  style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500)),
              const SizedBox(height: 6),
              DropdownButtonFormField<String>(
                value: _category, // ignore: deprecated_member_use
                dropdownColor: AppTheme.surface,
                style: const TextStyle(color: AppTheme.textPrimary),
                decoration: _inputDecoration(),
                items: _categories
                    .map((c) => DropdownMenuItem(
                        value: c,
                        child: Text(
                            c[0].toUpperCase() + c.substring(1))))
                    .toList(),
                onChanged: (v) => setState(() => _category = v ?? _category),
              ),
            ]),
            const SizedBox(height: 16),

            _Field(
              label: 'Funding goal (USD)',
              controller: _goalCtrl,
              hint: '50000',
              keyboardType: TextInputType.number,
              validator: (v) {
                final n = double.tryParse(v?.replaceAll(',', '') ?? '');
                if (n == null || n <= 0) return 'Enter a valid goal amount';
                return null;
              },
            ),
            const SizedBox(height: 16),

            _Field(
              label: 'Royalty % offered to backers',
              controller: _royaltyCtrl,
              hint: '15',
              keyboardType: TextInputType.number,
              suffix: '%',
              validator: (v) {
                final n = double.tryParse(v ?? '');
                if (n == null || n <= 0 || n > 100) {
                  return 'Enter a value between 0.01 and 100';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),

            _Field(
              label: 'Minimum investment (USD)',
              controller: _minInvestCtrl,
              hint: '10',
              keyboardType: TextInputType.number,
              validator: (v) {
                final n = double.tryParse(v?.replaceAll(',', '') ?? '');
                if (n == null || n < 10) return 'Minimum is \$10';
                return null;
              },
            ),
            const SizedBox(height: 16),

            _Field(
              label: 'Royalty term (years) — leave blank for perpetual',
              controller: _termCtrl,
              hint: 'e.g. 5',
              keyboardType: TextInputType.number,
              validator: (v) {
                if (v == null || v.trim().isEmpty) return null;
                final n = int.tryParse(v.trim());
                if (n == null || n <= 0) return 'Enter a positive whole number';
                return null;
              },
            ),
            const SizedBox(height: 32),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _saving ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                ),
                child: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Text('Save Draft',
                        style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
              ),
            ),
            const SizedBox(height: 40),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDecoration({String? hint, String? suffix}) =>
      InputDecoration(
        hintText: hint,
        suffixText: suffix,
        hintStyle: const TextStyle(color: AppTheme.textSecondary),
        filled: true,
        fillColor: AppTheme.surface,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppTheme.cardBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppTheme.cardBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppTheme.primary),
        ),
      );
}

class _Field extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? hint;
  final int maxLines;
  final TextInputType? keyboardType;
  final String? suffix;
  final String? Function(String?)? validator;

  const _Field({
    required this.label,
    required this.controller,
    this.hint,
    this.maxLines = 1,
    this.keyboardType,
    this.suffix,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    final decoration = InputDecoration(
      hintText: hint,
      suffixText: suffix,
      hintStyle: const TextStyle(color: AppTheme.textSecondary),
      filled: true,
      fillColor: AppTheme.surface,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppTheme.cardBorder),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppTheme.cardBorder),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppTheme.primary),
      ),
      errorBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(10),
        borderSide: const BorderSide(color: AppTheme.danger),
      ),
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label,
            style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13,
                fontWeight: FontWeight.w500)),
        const SizedBox(height: 6),
        TextFormField(
          controller: controller,
          maxLines: maxLines,
          keyboardType: keyboardType,
          style: const TextStyle(color: AppTheme.textPrimary),
          decoration: decoration,
          validator: validator,
        ),
      ],
    );
  }
}
