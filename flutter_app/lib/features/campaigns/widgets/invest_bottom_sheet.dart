import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/campaigns_providers.dart';

class InvestBottomSheet extends ConsumerStatefulWidget {
  final Campaign campaign;
  final WidgetRef ref;

  const InvestBottomSheet({
    super.key,
    required this.campaign,
    required this.ref,
  });

  @override
  ConsumerState<InvestBottomSheet> createState() => _InvestBottomSheetState();
}

class _InvestBottomSheetState extends ConsumerState<InvestBottomSheet> {
  final _amountCtrl = TextEditingController();
  bool _loading = false;
  String? _error;
  bool _success = false;

  @override
  void dispose() {
    _amountCtrl.dispose();
    super.dispose();
  }

  double get _dollars =>
      double.tryParse(_amountCtrl.text.replaceAll(',', '')) ?? 0;

  int get _cents => (_dollars * 100).round();

  double get _royaltyPctForAmount {
    final goal = widget.campaign.fundingGoalUsdCents;
    final offered = widget.campaign.royaltyPctOffered;
    if (goal <= 0 || _cents <= 0) return 0;
    return (_cents / goal) * offered;
  }

  Future<void> _invest() async {
    final dollars = _dollars;
    final minDollars = widget.campaign.minInvestmentUsdCents / 100;

    if (dollars < minDollars) {
      setState(() => _error = 'Minimum investment is \$${minDollars.toStringAsFixed(0)}');
      return;
    }

    setState(() {
      _loading = true;
      _error = null;
    });

    try {
      // Ensure sim balance and KYC exist (idempotent)
      await seedSimBalanceAndKyc();

      await investSimulated(
        campaignId: widget.campaign.id,
        royaltyPct: _royaltyPctForAmount,
        usdCents: _cents,
      );

      widget.ref.invalidate(campaignDetailProvider(widget.campaign.id));
      widget.ref.invalidate(simBalanceProvider);
      widget.ref.invalidate(myBackedCampaignsProvider);

      setState(() {
        _loading = false;
        _success = true;
      });
    } catch (e) {
      final msg = e.toString();
      setState(() {
        _loading = false;
        _error = msg.contains('INSUFFICIENT_SIM_BALANCE')
            ? 'Insufficient simulated balance'
            : msg.contains('KYC_REQUIRED')
                ? 'KYC verification required'
                : msg.contains('not open for investment')
                    ? 'Campaign is no longer accepting investments'
                    : 'Investment failed. Please try again.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final fmt = NumberFormat.currency(symbol: '\$', decimalDigits: 2);
    final simBalance = ref.watch(simBalanceProvider);

    return Padding(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: 24,
        bottom: MediaQuery.of(context).viewInsets.bottom + 32,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
            Text('Invest in ${widget.campaign.title}',
                style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.bold),
                maxLines: 1,
                overflow: TextOverflow.ellipsis),
            IconButton(
              icon: const Icon(Icons.close, color: AppTheme.textSecondary),
              onPressed: () => Navigator.pop(context),
            ),
          ]),
          const SizedBox(height: 4),
          const Text(
            'This is a simulated investment — no real money is used.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 16),

          // Sim balance display
          simBalance.when(
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
            data: (b) {
              final balance = b?.balanceUsdCents ?? 0;
              return Row(children: [
                const Icon(Icons.account_balance_wallet_outlined,
                    size: 14, color: AppTheme.textSecondary),
                const SizedBox(width: 4),
                Text(
                  'Sim balance: ${fmt.format(balance / 100)}',
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 13),
                ),
              ]);
            },
          ),
          const SizedBox(height: 16),

          if (_success) ...[
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.success.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(10),
                border:
                    Border.all(color: AppTheme.success.withValues(alpha: 0.35)),
              ),
              child: Row(children: [
                const Icon(Icons.check_circle_outline,
                    color: AppTheme.success, size: 20),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Investment confirmed! You now hold '
                    '${_royaltyPctForAmount.toStringAsFixed(4)}% royalty.',
                    style: const TextStyle(color: AppTheme.success),
                  ),
                ),
              ]),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done'),
              ),
            ),
          ] else ...[
            TextField(
              controller: _amountCtrl,
              keyboardType: TextInputType.number,
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 18),
              decoration: InputDecoration(
                prefixText: '\$ ',
                prefixStyle: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 18),
                hintText: '0',
                hintStyle: const TextStyle(color: AppTheme.textSecondary),
                filled: true,
                fillColor: AppTheme.background,
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
              ),
              onChanged: (_) => setState(() {}),
            ),
            if (_dollars > 0) ...[
              const SizedBox(height: 10),
              Text(
                'You will receive ~${_royaltyPctForAmount.toStringAsFixed(4)}% royalty stake',
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 13),
              ),
            ],
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!,
                  style: const TextStyle(
                      color: AppTheme.danger, fontSize: 13)),
            ],
            const SizedBox(height: 20),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _loading || _dollars <= 0 ? null : _invest,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.primary,
                  disabledBackgroundColor:
                      AppTheme.primary.withValues(alpha: 0.4),
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: _loading
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white),
                      )
                    : const Text(
                        'Confirm Investment',
                        style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold),
                      ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
