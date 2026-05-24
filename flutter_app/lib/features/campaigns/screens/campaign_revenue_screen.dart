import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/campaigns_providers.dart';

class CampaignRevenueScreen extends ConsumerStatefulWidget {
  final String campaignId;
  final String campaignTitle;
  final bool isSimulated;

  const CampaignRevenueScreen({
    super.key,
    required this.campaignId,
    required this.campaignTitle,
    required this.isSimulated,
  });

  @override
  ConsumerState<CampaignRevenueScreen> createState() =>
      _CampaignRevenueScreenState();
}

class _CampaignRevenueScreenState
    extends ConsumerState<CampaignRevenueScreen> {
  final _formKey = GlobalKey<FormState>();
  final _grossCtrl = TextEditingController();
  final _platformFeeCtrl = TextEditingController(text: '0');
  final _streamCtrl = TextEditingController(text: '0');
  final _viewCtrl = TextEditingController(text: '0');

  String _source = 'spotify';
  DateTime _periodStart = DateTime.now().subtract(const Duration(days: 30));
  DateTime _periodEnd = DateTime.now();
  bool _saving = false;

  static const _sources = [
    'spotify', 'youtube', 'apple_music', 'amazon_music', 'tidal',
    'soundcloud', 'bandcamp', 'twitch', 'distrokid', 'tunecore', 'manual', 'other',
  ];

  @override
  void dispose() {
    _grossCtrl.dispose();
    _platformFeeCtrl.dispose();
    _streamCtrl.dispose();
    _viewCtrl.dispose();
    super.dispose();
  }

  int get _grossCents =>
      ((double.tryParse(_grossCtrl.text.replaceAll(',', '')) ?? 0) * 100)
          .round();
  int get _platformFeeCents =>
      ((double.tryParse(_platformFeeCtrl.text.replaceAll(',', '')) ?? 0) * 100)
          .round();
  int get _netCents => (_grossCents - _platformFeeCents).clamp(0, _grossCents);

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);

    try {
      await submitRevenueEvent(
        campaignId: widget.campaignId,
        source: _source,
        periodStart: _periodStart,
        periodEnd: _periodEnd,
        grossCents: _grossCents,
        platformFeeCents: _platformFeeCents,
        netCents: _netCents,
        streamCount: int.tryParse(_streamCtrl.text) ?? 0,
        viewCount: int.tryParse(_viewCtrl.text) ?? 0,
      );

      if (mounted) {
        ref.invalidate(campaignRevenueEventsProvider(widget.campaignId));
        ref.invalidate(campaignDetailProvider(widget.campaignId));
        ref.invalidate(myDistributionsProvider);
        ref.invalidate(simBalanceProvider);

        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(widget.isSimulated
              ? 'Revenue submitted and distributions paid out!'
              : 'Revenue submitted for review.'),
          backgroundColor: AppTheme.success,
        ));
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(e.toString()),
          backgroundColor: AppTheme.danger,
        ));
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickDate(bool isStart) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: isStart ? _periodStart : _periodEnd,
      firstDate: DateTime(2020),
      lastDate: DateTime.now(),
      builder: (context, child) => Theme(
        data: ThemeData.dark().copyWith(
          colorScheme: const ColorScheme.dark(primary: AppTheme.primary),
        ),
        child: child!,
      ),
    );
    if (picked == null) return;
    setState(() {
      if (isStart) {
        _periodStart = picked;
        if (_periodEnd.isBefore(_periodStart)) _periodEnd = _periodStart;
      } else {
        _periodEnd = picked;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('MMM d, yyyy');
    final netFmt = NumberFormat.currency(symbol: '\$', decimalDigits: 2);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: const Text('Report Revenue'),
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            // Campaign context
            Text(widget.campaignTitle,
                style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            if (widget.isSimulated)
              const Text(
                'Simulation — distributions will be paid instantly from sim balances.',
                style: TextStyle(color: AppTheme.secondary, fontSize: 13),
              )
            else
              const Text(
                'Live mode — this event will be reviewed before distributions are sent.',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
              ),
            const SizedBox(height: 24),

            // Source
            _label('Revenue source'),
            const SizedBox(height: 6),
            DropdownButtonFormField<String>(
              value: _source, // ignore: deprecated_member_use
              dropdownColor: AppTheme.surface,
              style: const TextStyle(color: AppTheme.textPrimary),
              decoration: _inputDec(),
              items: _sources
                  .map((s) => DropdownMenuItem(
                      value: s, child: Text(s)))
                  .toList(),
              onChanged: (v) => setState(() => _source = v ?? _source),
            ),
            const SizedBox(height: 16),

            // Period
            Row(children: [
              Expanded(
                child: _DateButton(
                  label: 'Period start',
                  value: dateFmt.format(_periodStart),
                  onTap: () => _pickDate(true),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _DateButton(
                  label: 'Period end',
                  value: dateFmt.format(_periodEnd),
                  onTap: () => _pickDate(false),
                ),
              ),
            ]),
            const SizedBox(height: 16),

            // Revenue amounts
            _TextField(
              label: 'Gross revenue (USD)',
              controller: _grossCtrl,
              hint: '0.00',
              keyboardType: TextInputType.number,
              prefix: '\$ ',
              onChanged: (_) => setState(() {}),
              validator: (v) {
                final n =
                    double.tryParse(v?.replaceAll(',', '') ?? '');
                if (n == null || n <= 0) return 'Enter gross revenue';
                return null;
              },
            ),
            const SizedBox(height: 16),

            _TextField(
              label: "Platform's cut (Spotify, YouTube, etc.) (USD)",
              controller: _platformFeeCtrl,
              hint: '0.00',
              keyboardType: TextInputType.number,
              prefix: '\$ ',
              onChanged: (_) => setState(() {}),
            ),

            // Net preview
            if (_grossCents > 0) ...[
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: AppTheme.success.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                      color: AppTheme.success.withValues(alpha: 0.3)),
                ),
                child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Net to distribute',
                          style: TextStyle(color: AppTheme.textSecondary)),
                      Text(netFmt.format(_netCents / 100),
                          style: const TextStyle(
                              color: AppTheme.success,
                              fontWeight: FontWeight.bold)),
                    ]),
              ),
            ],
            const SizedBox(height: 16),

            // Optional metrics
            Row(children: [
              Expanded(
                child: _TextField(
                  label: 'Streams',
                  controller: _streamCtrl,
                  hint: '0',
                  keyboardType: TextInputType.number,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _TextField(
                  label: 'Views',
                  controller: _viewCtrl,
                  hint: '0',
                  keyboardType: TextInputType.number,
                ),
              ),
            ]),
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
                    : const Text('Submit Revenue',
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

  Widget _label(String text) => Text(text,
      style: const TextStyle(
          color: AppTheme.textSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w500));

  InputDecoration _inputDec({String? hint, String? prefix}) => InputDecoration(
        hintText: hint,
        prefixText: prefix,
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

class _TextField extends StatelessWidget {
  final String label;
  final TextEditingController controller;
  final String? hint;
  final TextInputType? keyboardType;
  final String? prefix;
  final ValueChanged<String>? onChanged;
  final String? Function(String?)? validator;

  const _TextField({
    required this.label,
    required this.controller,
    this.hint,
    this.keyboardType,
    this.prefix,
    this.onChanged,
    this.validator,
  });

  @override
  Widget build(BuildContext context) => Column(
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
            keyboardType: keyboardType,
            style: const TextStyle(color: AppTheme.textPrimary),
            onChanged: onChanged,
            validator: validator,
            decoration: InputDecoration(
              hintText: hint,
              prefixText: prefix,
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
            ),
          ),
        ],
      );
}

class _DateButton extends StatelessWidget {
  final String label;
  final String value;
  final VoidCallback onTap;

  const _DateButton({
    required this.label,
    required this.value,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label,
              style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500)),
          const SizedBox(height: 6),
          GestureDetector(
            onTap: onTap,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.cardBorder),
              ),
              child: Row(children: [
                const Icon(Icons.calendar_today_outlined,
                    size: 14, color: AppTheme.textSecondary),
                const SizedBox(width: 8),
                Text(value,
                    style: const TextStyle(color: AppTheme.textPrimary)),
              ]),
            ),
          ),
        ],
      );
}
