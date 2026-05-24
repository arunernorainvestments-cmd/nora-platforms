import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/campaigns_providers.dart';

class CampaignProposalCreateScreen extends StatefulWidget {
  final String campaignId;
  final int escrowBalanceCents;

  const CampaignProposalCreateScreen({
    super.key,
    required this.campaignId,
    required this.escrowBalanceCents,
  });

  @override
  State<CampaignProposalCreateScreen> createState() =>
      _CampaignProposalCreateScreenState();
}

class _CampaignProposalCreateScreenState
    extends State<CampaignProposalCreateScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _amountCtrl = TextEditingController();
  final _recipientCtrl = TextEditingController();
  String _category = 'equipment';
  bool _submitting = false;

  static const _categories = [
    'equipment', 'software', 'marketing', 'travel',
    'production', 'licensing', 'legal', 'distribution', 'other',
  ];

  int get _maxAmountCents =>
      (widget.escrowBalanceCents * 0.20).floor();

  @override
  void dispose() {
    _titleCtrl.dispose();
    _descCtrl.dispose();
    _amountCtrl.dispose();
    _recipientCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final fmt = NumberFormat.currency(symbol: '\$', decimalDigits: 0);
    final amountDollars = double.tryParse(_amountCtrl.text.replaceAll(',', ''));
    if (amountDollars == null) return;
    final amountCents = (amountDollars * 100).round();

    setState(() => _submitting = true);
    try {
      await createProposal(
        campaignId: widget.campaignId,
        title: _titleCtrl.text.trim(),
        description: _descCtrl.text.trim(),
        amountRequestedUsdCents: amountCents,
        purposeCategory: _category,
        recipientDescription: _recipientCtrl.text.trim(),
      );
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Proposal submitted — backers have 72 hours to vote. Max allowed: ${fmt.format(_maxAmountCents / 100)}'),
            backgroundColor: AppTheme.success,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
        );
        context.pop();
      }
    } catch (e) {
      if (mounted) {
        final msg = e.toString().contains('EXCEEDS_ESCROW_CAP')
            ? 'Amount exceeds 20% of escrow (max ${fmt.format(_maxAmountCents / 100)}).'
            : e.toString().contains('COOLING_PERIOD_ACTIVE')
                ? 'You must wait 30 days after a rejection before submitting a new proposal.'
                : e.toString().contains('CAMPAIGN_NOT_ELIGIBLE')
                    ? 'Proposals can only be created for funded or active campaigns.'
                    : 'Failed to submit proposal. Please try again.';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(msg),
            backgroundColor: AppTheme.danger,
            behavior: SnackBarBehavior.floating,
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10)),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.currency(symbol: '\$', decimalDigits: 0);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: const Text('New Proposal'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Form(
          key: _formKey,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Escrow info
              Container(
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: AppTheme.primary.withValues(alpha: 0.25)),
                ),
                child: Row(children: [
                  const Icon(Icons.info_outline,
                      color: AppTheme.primary, size: 16),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Escrow balance: ${fmt.format(widget.escrowBalanceCents / 100)}. '
                      'Max per proposal: ${fmt.format(_maxAmountCents / 100)} (20%).',
                      style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                          height: 1.4),
                    ),
                  ),
                ]),
              ),
              const SizedBox(height: 24),

              const _Label('Proposal title'),
              const SizedBox(height: 8),
              TextFormField(
                controller: _titleCtrl,
                style: const TextStyle(color: AppTheme.textPrimary),
                decoration: _inputDec('e.g. Studio session at Abbey Road'),
                maxLength: 120,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 16),

              const _Label('Description'),
              const SizedBox(height: 8),
              TextFormField(
                controller: _descCtrl,
                style: const TextStyle(color: AppTheme.textPrimary),
                decoration: _inputDec(
                    'Explain why this expense is necessary and how it benefits the work'),
                maxLines: 4,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 16),

              const _Label('Amount requested (USD)'),
              const SizedBox(height: 8),
              TextFormField(
                controller: _amountCtrl,
                style: const TextStyle(color: AppTheme.textPrimary),
                decoration: _inputDec('0'),
                keyboardType:
                    const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[\d,.]')),
                ],
                validator: (v) {
                  if (v == null || v.trim().isEmpty) return 'Required';
                  final d =
                      double.tryParse(v.replaceAll(',', ''));
                  if (d == null || d <= 0) return 'Enter a valid amount';
                  if ((d * 100).round() > _maxAmountCents) {
                    return 'Max ${fmt.format(_maxAmountCents / 100)} (20% of escrow)';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              const _Label('Category'),
              const SizedBox(height: 8),
              DropdownButtonFormField<String>(
                value: _category, // ignore: deprecated_member_use
                dropdownColor: AppTheme.surface,
                style: const TextStyle(color: AppTheme.textPrimary),
                decoration: _inputDec(''),
                items: _categories
                    .map((c) => DropdownMenuItem(
                          value: c,
                          child: Text(c,
                              style: const TextStyle(
                                  color: AppTheme.textPrimary)),
                        ))
                    .toList(),
                onChanged: (v) => setState(() => _category = v ?? _category),
              ),
              const SizedBox(height: 16),

              const _Label('Where funds will go'),
              const SizedBox(height: 8),
              TextFormField(
                controller: _recipientCtrl,
                style: const TextStyle(color: AppTheme.textPrimary),
                decoration: _inputDec(
                    'e.g. "Abbey Road Studios — 2-day recording session, invoice will be uploaded"'),
                maxLines: 3,
                validator: (v) =>
                    (v == null || v.trim().isEmpty) ? 'Required' : null,
              ),
              const SizedBox(height: 12),
              const Text(
                'Voting opens immediately and closes in 72 hours. '
                'A simple majority with 25% quorum is required to pass.',
                style: TextStyle(
                    color: AppTheme.textSecondary, fontSize: 12, height: 1.5),
              ),
              const SizedBox(height: 28),

              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  onPressed: _submitting ? null : _submit,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _submitting
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text('Submit Proposal',
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
      ),
    );
  }

  InputDecoration _inputDec(String hint) => InputDecoration(
        hintText: hint,
        hintStyle:
            const TextStyle(color: AppTheme.textSecondary, fontSize: 14),
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
        counterStyle:
            const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
      );
}

class _Label extends StatelessWidget {
  final String text;
  const _Label(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 14,
            fontWeight: FontWeight.w600),
      );
}
