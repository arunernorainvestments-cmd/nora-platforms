import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';

/// Public portal for management, labels, and legal representation to apply for
/// licensor partner status. Submits to lkn-partner-apply.
class PartnersPortalScreen extends ConsumerStatefulWidget {
  const PartnersPortalScreen({super.key});

  @override
  ConsumerState<PartnersPortalScreen> createState() =>
      _PartnersPortalScreenState();
}

class _PartnersPortalScreenState extends ConsumerState<PartnersPortalScreen> {
  final _formKey = GlobalKey<FormState>();
  final _company = TextEditingController();
  final _repName = TextEditingController();
  final _repEmail = TextEditingController();
  final _repPhone = TextEditingController();
  final _website = TextEditingController();
  final _talent = TextEditingController();

  static const _repTypes = <String, String>{
    'management': 'Management',
    'label': 'Record Label',
    'legal': 'Legal Representation',
    'publicist': 'Publicist',
    'studio': 'Studio',
    'agency': 'Agency',
    'other': 'Other',
  };
  String _repType = 'management';

  bool _submitting = false;
  bool _submitted = false;

  @override
  void dispose() {
    _company.dispose();
    _repName.dispose();
    _repEmail.dispose();
    _repPhone.dispose();
    _website.dispose();
    _talent.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate() || _submitting) return;
    final talentNames = _talent.text
        .split(RegExp(r'[\n,]'))
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();

    setState(() => _submitting = true);
    try {
      final resp = await Supabase.instance.client.functions.invoke(
        'lkn-partner-apply',
        body: {
          'company_name': _company.text.trim(),
          'representative_name': _repName.text.trim(),
          'representative_email': _repEmail.text.trim(),
          'representative_phone':
              _repPhone.text.trim().isEmpty ? null : _repPhone.text.trim(),
          'company_website':
              _website.text.trim().isEmpty ? null : _website.text.trim(),
          'representation_type': _repType,
          'talent_names': talentNames,
        },
      );
      final data = resp.data as Map<String, dynamic>?;
      if (data?['error'] != null) throw Exception(data!['error']);
      if (!mounted) return;
      setState(() => _submitted = true);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Submission failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: const Text('Partners',
            style: TextStyle(color: AppTheme.textPrimary)),
        iconTheme: const IconThemeData(color: AppTheme.textPrimary),
      ),
      body: _submitted ? _confirmation() : _form(),
    );
  }

  Widget _confirmation() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.mark_email_read_outlined,
                  size: 56, color: AppTheme.success),
              const SizedBox(height: 20),
              const Text('Application received',
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 22,
                      fontWeight: FontWeight.bold)),
              const SizedBox(height: 12),
              const Text(
                'Thanks for applying. Our team reviews partner applications within '
                '5 business days and will reach out at the email you provided.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 28),
              ElevatedButton(
                onPressed: () => context.go('/licenses'),
                child: const Text('Back to marketplace'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _form() {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620),
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(20),
            children: [
              const Text(
                'Are you management, a label, or legal representation?',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 22,
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              const Text(
                'Apply to license talent likenesses on their behalf. Verified '
                'partners can create and manage listings for the talent they represent.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 24),
              _field(_company, 'Company name', required: true),
              _dropdown(),
              _field(_repName, 'Representative name', required: true),
              _field(_repEmail, 'Representative email',
                  required: true, email: true),
              _field(_repPhone, 'Phone (optional)',
                  keyboard: TextInputType.phone),
              _field(_website, 'Company website (optional)'),
              _field(
                _talent,
                'Talent you represent (one per line or comma-separated)',
                maxLines: 4,
                required: true,
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: AppTheme.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: AppTheme.cardBorder),
                ),
                child: const Row(
                  children: [
                    Icon(Icons.upload_file,
                        size: 18, color: AppTheme.textSecondary),
                    SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Supporting documents (representation agreements, etc.) '
                        'can be requested during review.',
                        style: TextStyle(
                            color: AppTheme.textSecondary, fontSize: 12),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _submitting ? null : _submit,
                  child: _submitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Submit application'),
                ),
              ),
              const SizedBox(height: 12),
              const Text('Expected review timeline: 5 business days.',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }

  Widget _field(
    TextEditingController controller,
    String label, {
    bool required = false,
    bool email = false,
    int maxLines = 1,
    TextInputType? keyboard,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: TextFormField(
        controller: controller,
        maxLines: maxLines,
        keyboardType: keyboard,
        style: const TextStyle(color: AppTheme.textPrimary),
        decoration: InputDecoration(labelText: label),
        validator: (v) {
          final value = (v ?? '').trim();
          if (required && value.isEmpty) return 'Required';
          if (email && value.isNotEmpty && !value.contains('@')) {
            return 'Enter a valid email';
          }
          return null;
        },
      ),
    );
  }

  Widget _dropdown() {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: DropdownButtonFormField<String>(
        initialValue: _repType,
        dropdownColor: AppTheme.surface,
        style: const TextStyle(color: AppTheme.textPrimary),
        decoration: const InputDecoration(labelText: 'Representation type'),
        items: _repTypes.entries
            .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
            .toList(),
        onChanged: (v) => setState(() => _repType = v ?? 'management'),
      ),
    );
  }
}
