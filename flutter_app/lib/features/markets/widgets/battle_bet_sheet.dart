import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/n_glass_sheet.dart';
import '../providers/markets_providers.dart';

/// Opens the battle-market bet sheet for backing team 1 or team 2.
/// Team 1 maps to the market's `yes` pool, team 2 to the `no` pool — matching
/// distribute_match_revenue's pool semantics.
void showBattleBetSheet(
  BuildContext context, {
  required BattleMarket market,
  VoidCallback? onBetPlaced,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => _BattleBetSheet(market: market, onBetPlaced: onBetPlaced),
  );
}

class _BattleBetSheet extends ConsumerStatefulWidget {
  final BattleMarket market;
  final VoidCallback? onBetPlaced;

  const _BattleBetSheet({required this.market, this.onBetPlaced});

  @override
  ConsumerState<_BattleBetSheet> createState() => _BattleBetSheetState();
}

class _BattleBetSheetState extends ConsumerState<_BattleBetSheet> {
  int _step = 0; // 0 = team, 1 = amount, 2 = confirm
  String? _position; // 'team_1' or 'team_2' (settles via distribute_match_revenue)
  int _amount = 10;
  final _customController = TextEditingController();
  bool _useCustom = false;

  int _tokenBalance = 0;
  bool _loadingBalance = true;
  bool _isSubmitting = false;
  bool _success = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _loadBalance();
  }

  @override
  void dispose() {
    _customController.dispose();
    super.dispose();
  }

  Future<void> _loadBalance() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      setState(() => _loadingBalance = false);
      return;
    }
    try {
      final res = await Supabase.instance.client
          .from('token_balances')
          .select('available_tokens')
          .eq('user_id', userId)
          .maybeSingle();
      if (mounted) {
        setState(() {
          _tokenBalance = (res?['available_tokens'] as num?)?.toInt() ?? 0;
          _loadingBalance = false;
        });
      }
    } catch (_) {
      if (mounted) setState(() => _loadingBalance = false);
    }
  }

  int get _effectiveAmount =>
      _useCustom ? (int.tryParse(_customController.text) ?? 0) : _amount;

  double get _estimatedPayout {
    final amount = _effectiveAmount.toDouble();
    final myPool = _position == 'team_1'
        ? widget.market.team1Pool
        : widget.market.team2Pool;
    final total = widget.market.totalPool;
    final denom = myPool + amount;
    if (denom == 0) return 0;
    return (amount / denom) * (total + amount) * 0.98;
  }

  Future<void> _confirm() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) {
      setState(() => _error = 'Please log in to place a bet');
      return;
    }
    final amount = _effectiveAmount;
    if (amount <= 0) {
      setState(() => _error = 'Enter a valid amount');
      return;
    }
    if (amount > _tokenBalance) {
      setState(() => _error = 'Insufficient token balance');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      final payout = _estimatedPayout;
      // The bets insert trigger updates pools, deducts tokens, logs the
      // transaction, and notifies — same path as creator markets.
      await Supabase.instance.client.from('bets').insert({
        'market_id': widget.market.id,
        'user_id': userId,
        'position': _position,
        'amount': amount,
        'potential_payout': payout > 0 ? payout : null,
        'status': 'active',
      });

      if (mounted) {
        setState(() {
          _success = true;
          _isSubmitting = false;
        });
        widget.onBetPlaced?.call();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = _betError(e.toString());
          _isSubmitting = false;
        });
      }
    }
  }

  String _betError(String raw) {
    if (raw.contains('Insufficient token balance')) {
      return 'Insufficient token balance';
    }
    if (raw.contains('combatants cannot bet')) {
      return 'You\'re competing in this match — you can\'t bet on your own battle.';
    }
    if (raw.contains('KYC verification required')) {
      return 'Verify your identity to place a bet.';
    }
    return 'Failed to place bet. Please try again.';
  }

  @override
  Widget build(BuildContext context) {
    final keyboardPad = MediaQuery.of(context).viewInsets.bottom;

    return NGlassSheet(
      padding: EdgeInsets.fromLTRB(24, 20, 24, 24 + keyboardPad),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const NSheetHandle(),
          const SizedBox(height: 20),
          if (_success)
            _SuccessView(onClose: () => Navigator.of(context).pop())
          else if (_step == 0)
            _buildTeamStep()
          else if (_step == 1)
            _buildAmountStep()
          else
            _buildConfirmStep(),
        ],
      ),
    );
  }

  // ── Step 0: choose team ──────────────────────────────────────────────────
  Widget _buildTeamStep() {
    final m = widget.market;
    final total = m.totalPool;
    final t1Ratio = total > 0 ? m.team1Pool / total : 0.5;
    final hasPool = total > 0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Back a Team',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 6),
        Text('Who wins this battle?',
            style: TextStyle(
                color: AppTheme.textSecondary.withValues(alpha: 0.9),
                fontSize: 13)),
        const SizedBox(height: 20),
        if (hasPool) ...[
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('${(t1Ratio * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                      color: AppTheme.success,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
              Text('${((1 - t1Ratio) * 100).toStringAsFixed(0)}%',
                  style: const TextStyle(
                      color: AppTheme.primary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 8,
              child: Row(children: [
                Expanded(
                    flex: (t1Ratio * 100).round().clamp(1, 100),
                    child: Container(color: AppTheme.success)),
                Expanded(
                    flex: ((1 - t1Ratio) * 100).round().clamp(1, 100),
                    child: Container(color: AppTheme.primary)),
              ]),
            ),
          ),
          const SizedBox(height: 16),
        ],
        _TeamButton(
          label: m.team1Label,
          color: AppTheme.success,
          pool: m.team1Pool,
          showPool: hasPool,
          isSelected: _position == 'team_1',
          onTap: () => setState(() => _position = 'team_1'),
        ),
        const SizedBox(height: 10),
        _TeamButton(
          label: m.team2Label,
          color: AppTheme.primary,
          pool: m.team2Pool,
          showPool: hasPool,
          isSelected: _position == 'team_2',
          onTap: () => setState(() => _position = 'team_2'),
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _position != null ? () => setState(() => _step = 1) : null,
          child: const Text('Next'),
        ),
      ],
    );
  }

  // ── Step 1: amount ───────────────────────────────────────────────────────
  Widget _buildAmountStep() {
    const quickAmounts = [10, 25, 50, 100];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          IconButton(
            onPressed: () => setState(() => _step = 0),
            icon: const Icon(Icons.arrow_back,
                color: AppTheme.textSecondary, size: 20),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
          const SizedBox(width: 8),
          const Text('Choose Amount',
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 6),
        Row(children: [
          const Icon(Icons.toll_outlined,
              size: 14, color: AppTheme.textSecondary),
          const SizedBox(width: 4),
          Text(
            _loadingBalance
                ? 'Balance: …'
                : 'Balance: $_tokenBalance tokens',
            style:
                const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
        ]),
        const SizedBox(height: 20),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: quickAmounts.map((a) {
            final isSelected = !_useCustom && _amount == a;
            return GestureDetector(
              onTap: () => setState(() {
                _amount = a;
                _useCustom = false;
              }),
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppTheme.primary.withValues(alpha: 0.15)
                      : AppTheme.surfaceLight,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isSelected ? AppTheme.primary : AppTheme.cardBorder,
                    width: isSelected ? 2 : 1,
                  ),
                ),
                child: Text('$a',
                    style: TextStyle(
                        color: isSelected
                            ? AppTheme.primary
                            : AppTheme.textPrimary,
                        fontWeight: FontWeight.w600,
                        fontSize: 15)),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _customController,
          keyboardType: TextInputType.number,
          inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          onTap: () => setState(() => _useCustom = true),
          onChanged: (_) => setState(() => _useCustom = true),
          decoration: InputDecoration(
            labelText: 'Custom amount',
            prefixIcon: const Icon(Icons.edit_outlined,
                color: AppTheme.textSecondary, size: 18),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: BorderSide(
                color: _useCustom ? AppTheme.primary : AppTheme.cardBorder,
                width: _useCustom ? 2 : 1,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(12),
              borderSide: const BorderSide(color: AppTheme.primary, width: 2),
            ),
          ),
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.surfaceLight,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.cardBorder),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Est. payout if you win',
                  style:
                      TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
              Text(
                _estimatedPayout > 0
                    ? '${_estimatedPayout.toStringAsFixed(1)} tokens'
                    : '—',
                style: const TextStyle(
                    color: AppTheme.success,
                    fontWeight: FontWeight.bold,
                    fontSize: 14),
              ),
            ],
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 10),
          Text(_error!,
              style: const TextStyle(color: AppTheme.danger, fontSize: 13)),
        ],
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: () {
            final a = _effectiveAmount;
            if (a <= 0) {
              setState(() => _error = 'Enter a valid amount');
              return;
            }
            if (a > _tokenBalance) {
              setState(() => _error = 'Insufficient token balance');
              return;
            }
            setState(() {
              _error = null;
              _step = 2;
            });
          },
          child: const Text('Next'),
        ),
      ],
    );
  }

  // ── Step 2: confirm ──────────────────────────────────────────────────────
  Widget _buildConfirmStep() {
    final m = widget.market;
    final teamLabel = _position == 'team_1' ? m.team1Label : m.team2Label;
    final teamColor =
        _position == 'team_1' ? AppTheme.success : AppTheme.primary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(children: [
          IconButton(
            onPressed: _isSubmitting ? null : () => setState(() => _step = 1),
            icon: const Icon(Icons.arrow_back,
                color: AppTheme.textSecondary, size: 20),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
          ),
          const SizedBox(width: 8),
          const Text('Confirm Bet',
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
        ]),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppTheme.surfaceLight,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.cardBorder),
          ),
          child: Column(children: [
            _row('Backing', teamLabel, valueColor: teamColor),
            const SizedBox(height: 10),
            _row('Amount', '$_effectiveAmount tokens'),
            const SizedBox(height: 10),
            _row(
              'Est. payout if win',
              _estimatedPayout > 0
                  ? '${_estimatedPayout.toStringAsFixed(1)} tokens'
                  : 'N/A',
              valueColor: AppTheme.success,
            ),
          ]),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!,
              style: const TextStyle(color: AppTheme.danger, fontSize: 13)),
          if (_error!.contains('Verify your identity')) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                context.go('/verify-identity');
              },
              icon: const Icon(Icons.badge_outlined, size: 18),
              label: const Text('Verify identity'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.primary,
                side: const BorderSide(color: AppTheme.primary),
                minimumSize: const Size(double.infinity, 44),
              ),
            ),
          ],
        ],
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: _isSubmitting ? null : _confirm,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.success,
            minimumSize: const Size(double.infinity, 50),
          ),
          child: _isSubmitting
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Text('Confirm Bet'),
        ),
      ],
    );
  }

  Widget _row(String label, String value, {Color? valueColor}) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style:
                  const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
          Text(value,
              style: TextStyle(
                  color: valueColor ?? AppTheme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
        ],
      );
}

class _TeamButton extends StatelessWidget {
  final String label;
  final Color color;
  final double pool;
  final bool showPool;
  final bool isSelected;
  final VoidCallback onTap;

  const _TeamButton({
    required this.label,
    required this.color,
    required this.pool,
    required this.showPool,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: isSelected
              ? color.withValues(alpha: 0.15)
              : AppTheme.surfaceLight,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected ? color : AppTheme.cardBorder,
            width: isSelected ? 2 : 1,
          ),
        ),
        child: Row(children: [
          Icon(Icons.shield_outlined, color: color, size: 22),
          const SizedBox(width: 12),
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    color: isSelected ? color : AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w600)),
          ),
          if (showPool)
            Text('${pool.toStringAsFixed(0)} tokens',
                style: TextStyle(
                    color: color.withValues(alpha: 0.8),
                    fontSize: 12,
                    fontWeight: FontWeight.w600)),
        ]),
      ),
    );
  }
}

class _SuccessView extends StatelessWidget {
  final VoidCallback onClose;
  const _SuccessView({required this.onClose});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 12),
          const Center(
            child: Icon(Icons.check_circle_outline,
                size: 56, color: AppTheme.success),
          ),
          const SizedBox(height: 16),
          const Text('Bet Placed!',
              textAlign: TextAlign.center,
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
            'You\'ll be paid out if your team wins the battle.',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: AppTheme.textSecondary, fontSize: 14, height: 1.5),
          ),
          const SizedBox(height: 28),
          ElevatedButton(onPressed: onClose, child: const Text('Done')),
          const SizedBox(height: 8),
        ],
      );
}
