import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/ubi_providers.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/widgets/n_back_button.dart';

class RequestFundsScreen extends ConsumerStatefulWidget {
  const RequestFundsScreen({super.key});

  @override
  ConsumerState<RequestFundsScreen> createState() => _RequestFundsScreenState();
}

class _RequestFundsScreenState extends ConsumerState<RequestFundsScreen> {
  int _step = 0;

  // Step 1
  final _amountController = TextEditingController();
  int? _amountCents;

  // Step 2
  String _category = 'medical';

  // Step 3
  final _narrativeController = TextEditingController();

  // Step 4 — AI review result
  String? _requestId;
  List<Map<String, dynamic>> _documentsRequested = [];
  Timer? _pollTimer;

  // Step 5 — document upload state
  final Map<String, bool> _uploadedTypes = {};

  bool _isSubmitting = false;

  static const _categories = [
    ('medical', 'Medical', Icons.local_hospital_outlined),
    ('housing', 'Housing', Icons.home_outlined),
    ('utilities', 'Utilities', Icons.bolt_outlined),
    ('food', 'Food', Icons.restaurant_outlined),
    ('transportation', 'Transportation', Icons.directions_car_outlined),
    ('funeral', 'Funeral', Icons.sentiment_very_dissatisfied_outlined),
    ('disaster', 'Disaster', Icons.warning_amber_outlined),
    ('other', 'Other', Icons.more_horiz),
  ];

  @override
  void dispose() {
    _amountController.dispose();
    _narrativeController.dispose();
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _submitRequest() async {
    final narrative = _narrativeController.text.trim();
    if (narrative.length < 100) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please provide more detail (minimum 100 characters).')),
      );
      return;
    }

    setState(() => _isSubmitting = true);
    try {
      final resp = await Supabase.instance.client.functions.invoke(
        'ubi-submit-request',
        body: {
          'amount_usd_cents': _amountCents,
          'emergency_category': _category,
          'request_narrative': narrative,
        },
      );
      _requestId = resp.data?['request_id'] as String?;
      if (_requestId == null) throw Exception('No request_id returned');

      setState(() => _step = 3);
      _startPollingAiStatus();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Failed to submit: $e')),
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  void _startPollingAiStatus() {
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) async {
      if (_requestId == null) return;
      final data = await Supabase.instance.client
          .from('ubi_withdrawal_requests')
          .select('status')
          .eq('id', _requestId!)
          .maybeSingle();

      final status = data?['status'] as String?;
      if (status == null || status == 'pending_ai_review') return;

      _pollTimer?.cancel();

      if (!mounted) return;

      if (status == 'voided') {
        setState(() => _step = 3);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(
            'Your request was not accepted. Emergency funds are for genuine emergencies only.'
          )),
        );
        return;
      }

      // Fetch documents requested by AI
      final evalData = await Supabase.instance.client
          .from('ubi_ai_evaluations')
          .select('documents_requested')
          .eq('request_id', _requestId!)
          .eq('evaluation_pass', 1)
          .maybeSingle();

      final docs = evalData?['documents_requested'] as List<dynamic>? ?? [];
      final typed = docs.map((d) => d as Map<String, dynamic>).toList();

      if (!mounted) return;
      if (status == 'pending_documents' && typed.isNotEmpty) {
        setState(() {
          _documentsRequested = typed;
          _step = 4;
        });
      } else {
        setState(() => _step = 5);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final balanceAsync = ref.watch(ubiPoolBalanceProvider);
    final configAsync = ref.watch(ubiPoolConfigProvider);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: const NBackButton(fallback: '/emergency-fund'),
        backgroundColor: AppTheme.surface,
        title: const Text('Request Funds',
            style: TextStyle(color: AppTheme.textPrimary)),
        iconTheme: const IconThemeData(color: AppTheme.textPrimary),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(4),
          child: LinearProgressIndicator(
            value: (_step + 1) / 6,
            backgroundColor: AppTheme.cardBorder,
            color: AppTheme.primary,
          ),
        ),
      ),
      body: configAsync.when(
        data: (config) {
          if (!config.isOpenForRequests) {
            return const Center(
              child: Text('The fund is not currently accepting requests.',
                  style: TextStyle(color: AppTheme.textSecondary)),
            );
          }
          return balanceAsync.when(
            data: (balance) => _buildStep(config, balance),
            loading: () => _buildStep(config, null),
            error: (_, __) => _buildStep(config, null),
          );
        },
        loading: () => const Center(child: CircularProgressIndicator(color: AppTheme.primary)),
        error: (e, _) => Center(child: Text('$e', style: const TextStyle(color: AppTheme.danger))),
      ),
    );
  }

  Widget _buildStep(dynamic config, dynamic balance) {
    return switch (_step) {
      0 => _buildAmountStep(config, balance),
      1 => _buildCategoryStep(),
      2 => _buildNarrativeStep(),
      3 => _buildAiReviewStep(),
      4 => _buildDocumentUploadStep(),
      _ => _buildSubmittedStep(),
    };
  }

  Widget _buildAmountStep(dynamic config, dynamic balance) {
    final simBalance = (balance?.simBalanceCents ?? 0) as int;
    final liveBalance = (balance?.liveBalanceCents ?? 0) as int;
    final poolBalance = config.isSimulated ? simBalance : liveBalance;
    final maxByPct = (poolBalance * 0.1).floor();
    final cap = [maxByPct, 100000].reduce((a, b) => a < b ? a : b);
    final capDollars = (cap / 100).toStringAsFixed(0);
    final poolDollars = (poolBalance / 100).toStringAsFixed(0);

    return _StepContainer(
      title: 'How much do you need?',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Pool balance: \$$poolDollars · Maximum request: \$$capDollars',
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _amountController,
            style: const TextStyle(color: AppTheme.textPrimary),
            keyboardType: TextInputType.number,
            decoration: InputDecoration(
              labelText: 'Amount (USD)',
              labelStyle: const TextStyle(color: AppTheme.textSecondary),
              prefixText: '\$ ',
              prefixStyle: const TextStyle(color: AppTheme.textPrimary),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppTheme.cardBorder),
              ),
            ),
            onChanged: (v) {
              final parsed = double.tryParse(v);
              setState(() {
                _amountCents = parsed != null ? (parsed * 100).round() : null;
              });
            },
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: _amountCents != null &&
                    _amountCents! > 0 &&
                    _amountCents! <= cap
                ? () => setState(() => _step = 1)
                : null,
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.primary,
              minimumSize: const Size(double.infinity, 48),
            ),
            child: const Text('Next'),
          ),
        ],
      ),
    );
  }

  Widget _buildCategoryStep() {
    return _StepContainer(
      title: 'What type of emergency?',
      child: RadioGroup<String>(
        groupValue: _category,
        onChanged: (v) { if (v != null) setState(() => _category = v); },
        child: Column(
        children: [
          ..._categories.map((cat) => RadioListTile<String>(
                value: cat.$1,
                title: Row(
                  children: [
                    Icon(cat.$3, color: AppTheme.primary, size: 18),
                    const SizedBox(width: 8),
                    Text(cat.$2,
                        style: const TextStyle(color: AppTheme.textPrimary)),
                  ],
                ),
                contentPadding: EdgeInsets.zero,
              )),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () => setState(() => _step = 2),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.primary,
              minimumSize: const Size(double.infinity, 48),
            ),
            child: const Text('Next'),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildNarrativeStep() {
    final charCount = _narrativeController.text.length;

    return _StepContainer(
      title: 'Tell us what happened',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.primary.withValues(alpha: 0.2)),
            ),
            child: const Text(
              'What you write here is private. Our AI will read it to understand '
              'your situation, but your words will never be shown to voters.',
              style: TextStyle(color: AppTheme.primary, fontSize: 13),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _narrativeController,
            style: const TextStyle(color: AppTheme.textPrimary),
            maxLines: 8,
            decoration: InputDecoration(
              hintText: 'In your own words, tell us what happened and why you need help.',
              hintStyle: const TextStyle(color: AppTheme.textSecondary),
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(color: AppTheme.cardBorder),
              ),
            ),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 4),
          Text(
            '$charCount / 100 minimum',
            style: TextStyle(
                color: charCount >= 100 ? AppTheme.success : AppTheme.textSecondary,
                fontSize: 12),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: charCount >= 100 && !_isSubmitting ? _submitRequest : null,
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.primary,
              minimumSize: const Size(double.infinity, 48),
            ),
            child: _isSubmitting
                ? const CircularProgressIndicator(color: Colors.white)
                : const Text('Submit for Review'),
          ),
        ],
      ),
    );
  }

  Widget _buildAiReviewStep() {
    return const _StepContainer(
      title: 'Reviewing your request…',
      child: Column(
        children: [
          CircularProgressIndicator(color: AppTheme.primary),
          SizedBox(height: 20),
          Text(
            'Our AI is reviewing your request privately. This usually takes under a minute.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildDocumentUploadStep() {
    return _StepContainer(
      title: 'Supporting documents',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: AppTheme.primary.withValues(alpha: 0.2)),
            ),
            child: const Text(
              'Documents are read only by the AI. Voters never see them.',
              style: TextStyle(color: AppTheme.primary, fontSize: 13),
            ),
          ),
          const SizedBox(height: 16),
          ..._documentsRequested.map((doc) {
            final type = doc['type'] as String;
            final label = doc['label'] as String;
            final rationale = doc['rationale'] as String? ?? '';
            final uploaded = _uploadedTypes[type] ?? false;

            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: uploaded ? AppTheme.success : AppTheme.cardBorder,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    uploaded ? Icons.check_circle : Icons.upload_file,
                    color: uploaded ? AppTheme.success : AppTheme.textSecondary,
                    size: 20,
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(label,
                            style: const TextStyle(
                                color: AppTheme.textPrimary,
                                fontWeight: FontWeight.w600)),
                        if (rationale.isNotEmpty)
                          Text(rationale,
                              style: const TextStyle(
                                  color: AppTheme.textSecondary, fontSize: 12)),
                      ],
                    ),
                  ),
                  if (!uploaded)
                    TextButton(
                      onPressed: () => _pickAndUploadDocument(type, label),
                      child: const Text('Upload',
                          style: TextStyle(color: AppTheme.primary)),
                    ),
                ],
              ),
            );
          }),
          const SizedBox(height: 8),
          const Text(
            'Accepted formats: PDF, JPEG, PNG (max 10 MB each)',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Future<void> _pickAndUploadDocument(String type, String label) async {
    // Document file picking is platform-dependent. On web, use html.FileUploadInputElement.
    // For now show a snackbar indicating the upload flow is ready.
    // Full file-picker integration requires the file_picker package.
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('File picker coming soon — upload via web input')),
    );
  }

  Widget _buildSubmittedStep() {
    return _StepContainer(
      title: 'Your request is with the community',
      child: Column(
        children: [
          const Icon(Icons.how_to_vote, color: AppTheme.success, size: 56),
          const SizedBox(height: 16),
          const Text(
            'A community panel will review your request. '
            'You\'ll be notified within 72 hours.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          FilledButton(
            onPressed: () => context.go('/emergency-fund/my-requests'),
            style: FilledButton.styleFrom(
              backgroundColor: AppTheme.primary,
              minimumSize: const Size(double.infinity, 48),
            ),
            child: const Text('View My Requests'),
          ),
        ],
      ),
    );
  }
}

class _StepContainer extends StatelessWidget {
  final String title;
  final Widget child;

  const _StepContainer({required this.title, required this.child});

  @override
  Widget build(BuildContext context) => ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Text(title,
              style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 20),
          child,
        ],
      );
}
