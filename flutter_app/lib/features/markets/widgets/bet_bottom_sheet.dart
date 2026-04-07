import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';

// ─────────────────────────────────────────────────────────────────────────────
// PUBLIC ENTRY POINT
// ─────────────────────────────────────────────────────────────────────────────

/// Opens the bet bottom sheet. If [initialTimeframe] is provided, step 1
/// (timeframe selection) is skipped and the sheet opens at step 2.
void showBetBottomSheet(
  BuildContext context, {
  required String creatorId,
  required String creatorUsername,
  String? initialTimeframe,
  VoidCallback? onBetPlaced,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => BetBottomSheet(
      creatorId: creatorId,
      creatorUsername: creatorUsername,
      initialTimeframe: initialTimeframe,
      onBetPlaced: onBetPlaced,
    ),
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// WIDGET
// ─────────────────────────────────────────────────────────────────────────────

class BetBottomSheet extends ConsumerStatefulWidget {
  final String creatorId;
  final String creatorUsername;
  final String? initialTimeframe;
  final VoidCallback? onBetPlaced;

  const BetBottomSheet({
    super.key,
    required this.creatorId,
    required this.creatorUsername,
    this.initialTimeframe,
    this.onBetPlaced,
  });

  @override
  ConsumerState<BetBottomSheet> createState() => _BetBottomSheetState();
}

class _BetBottomSheetState extends ConsumerState<BetBottomSheet> {
  // Start at step 1 unless a timeframe was pre-selected (join flow)
  late int _step;
  late String _timeframe;

  String? _position; // 'yes' | 'no'
  int _amount = 10;
  final _customAmountController = TextEditingController();
  bool _useCustom = false;

  // Fetched when entering step 2
  double _existingYesPool = 0;
  double _existingNoPool = 0;
  String? _existingMarketId;

  // Fetched when entering step 2
  int _tokenBalance = 0;

  bool _isLoading = false;
  bool _isSubmitting = false;
  String? _error;
  bool _success = false;

  static const _timeframeLabels = {
    '24h': '24 Hours',
    '7d': '7 Days',
    '30d': '30 Days',
  };

  @override
  void initState() {
    super.initState();
    _timeframe = widget.initialTimeframe ?? '7d';
    _step = widget.initialTimeframe != null ? 1 : 0;
    if (widget.initialTimeframe != null) {
      _loadStep2Data();
    }
  }

  @override
  void dispose() {
    _customAmountController.dispose();
    super.dispose();
  }

  int get _effectiveAmount =>
      _useCustom ? (int.tryParse(_customAmountController.text) ?? 0) : _amount;

  double get _estimatedPayout {
    final amount = _effectiveAmount.toDouble();
    final myPool = _position == 'yes' ? _existingYesPool : _existingNoPool;
    final total = _existingYesPool + _existingNoPool;
    final denominator = myPool + amount;
    if (denominator == 0) return 0;
    return (amount / denominator) * total * 0.98;
  }

  DateTime _endAt(String timeframe) {
    final now = DateTime.now().toUtc();
    return switch (timeframe) {
      '24h' => now.add(const Duration(hours: 24)),
      '7d' => now.add(const Duration(days: 7)),
      _ => now.add(const Duration(days: 30)),
    };
  }

  Future<void> _loadStep2Data() async {
    setState(() { _isLoading = true; _error = null; });
    try {
      final client = Supabase.instance.client;

      // Load existing open market for this creator + timeframe
      final existingMarket = await client
          .from('markets')
          .select('id, yes_pool, no_pool')
          .eq('creator_id', widget.creatorId)
          .eq('timeframe', _timeframe)
          .eq('status', 'open')
          .maybeSingle();

      if (existingMarket != null) {
        _existingMarketId = existingMarket['id'] as String;
        _existingYesPool = (existingMarket['yes_pool'] as num?)?.toDouble() ?? 0;
        _existingNoPool = (existingMarket['no_pool'] as num?)?.toDouble() ?? 0;
      } else {
        _existingMarketId = null;
        _existingYesPool = 0;
        _existingNoPool = 0;
      }

      // Load token balance
      final userId = client.auth.currentUser?.id;
      if (userId != null) {
        final balanceData = await client
            .from('token_balances')
            .select('available_tokens')
            .eq('user_id', userId)
            .maybeSingle();
        _tokenBalance = (balanceData?['available_tokens'] as num?)?.toInt() ?? 0;
      }
    } catch (e) {
      _error = e.toString();
    } finally {
      if (mounted) setState(() { _isLoading = false; });
    }
  }

  Future<void> _confirmBet() async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) return;

    final amount = _effectiveAmount;
    if (amount <= 0) {
      setState(() => _error = 'Enter a valid amount');
      return;
    }
    if (amount > _tokenBalance) {
      setState(() => _error = 'Insufficient token balance');
      return;
    }

    setState(() { _isSubmitting = true; _error = null; });

    try {
      final client = Supabase.instance.client;
      String marketId;

      if (_existingMarketId != null) {
        marketId = _existingMarketId!;
      } else {
        // Create a new market
        final marketResult = await client.from('markets').insert({
          'creator_id': widget.creatorId,
          'created_by': userId,
          'opened_by': userId,
          'title': '@${widget.creatorUsername}\'s ${_timeframeLabels[_timeframe]} popularity market',
          'timeframe': _timeframe,
          'end_at': _endAt(_timeframe).toIso8601String(),
          'status': 'open',
        }).select('id').single();
        marketId = marketResult['id'] as String;
      }

      // Calculate potential payout estimate
      final payout = _estimatedPayout;

      // Insert the bet — the DB trigger handles:
      //   • updating market yes_pool/no_pool
      //   • deducting tokens from token_balances
      //   • inserting a token_transaction record
      //   • notifying the market maker
      await client.from('bets').insert({
        'market_id': marketId,
        'user_id': userId,
        'position': _position,
        'amount': amount,
        'potential_payout': payout > 0 ? payout : null,
        'status': 'active',
      });

      if (mounted) {
        setState(() { _success = true; _isSubmitting = false; });
        widget.onBetPlaced?.call();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = e.toString().contains('Insufficient token balance')
              ? 'Insufficient token balance'
              : 'Failed to place bet. Please try again.';
          _isSubmitting = false;
        });
      }
    }
  }

  void _nextStep() {
    if (_step == 0) {
      // Timeframe selected → load pool data then move to position step
      _loadStep2Data().then((_) {
        if (mounted && _error == null) setState(() => _step = 1);
      });
    } else {
      setState(() => _step++);
    }
  }

  void _prevStep() {
    if (_step > 0) setState(() => _step--);
  }

  @override
  Widget build(BuildContext context) {
    final keyboardPad = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(24, 20, 24, 24 + keyboardPad),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Drag handle
          Center(
            child: Container(
              width: 40,
              height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: AppTheme.cardBorder,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),

          if (_success)
            _SuccessView(onClose: () => Navigator.of(context).pop())
          else if (_step == 0)
            _StepTimeframe(
              selected: _timeframe,
              onSelect: (t) => setState(() => _timeframe = t),
              onNext: _nextStep,
              isLoading: _isLoading,
            )
          else if (_step == 1)
            _StepPosition(
              creatorUsername: widget.creatorUsername,
              timeframe: _timeframe,
              yesPool: _existingYesPool,
              noPool: _existingNoPool,
              selected: _position,
              onSelect: (p) => setState(() => _position = p),
              onNext: () => setState(() => _step = 2),
              onBack: widget.initialTimeframe == null ? _prevStep : null,
            )
          else if (_step == 2)
            _StepAmount(
              tokenBalance: _tokenBalance,
              yesPool: _existingYesPool,
              noPool: _existingNoPool,
              position: _position!,
              selectedAmount: _amount,
              useCustom: _useCustom,
              customController: _customAmountController,
              estimatedPayout: _estimatedPayout,
              onQuickAmount: (a) => setState(() {
                _amount = a;
                _useCustom = false;
              }),
              onCustomToggle: () => setState(() => _useCustom = true),
              onBack: _prevStep,
              onNext: () {
                final a = _effectiveAmount;
                if (a <= 0) {
                  setState(() => _error = 'Enter a valid amount');
                  return;
                }
                if (a > _tokenBalance) {
                  setState(() => _error = 'Insufficient token balance');
                  return;
                }
                setState(() { _error = null; _step = 3; });
              },
              error: _error,
            )
          else
            _StepConfirm(
              creatorUsername: widget.creatorUsername,
              timeframe: _timeframe,
              position: _position!,
              amount: _effectiveAmount,
              estimatedPayout: _estimatedPayout,
              isNew: _existingMarketId == null,
              isSubmitting: _isSubmitting,
              error: _error,
              onBack: _prevStep,
              onConfirm: _confirmBet,
            ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// STEP 1: TIMEFRAME
// ─────────────────────────────────────────────────────────────────────────────

class _StepTimeframe extends StatelessWidget {
  final String selected;
  final void Function(String) onSelect;
  final VoidCallback onNext;
  final bool isLoading;

  const _StepTimeframe({
    required this.selected,
    required this.onSelect,
    required this.onNext,
    required this.isLoading,
  });

  @override
  Widget build(BuildContext context) {
    const timeframes = [
      ('24h', '24 Hours', 'Resolves based on popularity score change over 24 hours'),
      ('7d', '7 Days', 'Resolves based on popularity score change over 7 days'),
      ('30d', '30 Days', 'Resolves based on popularity score change over 30 days'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Choose Timeframe',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'How long should this market run?',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
        ),
        const SizedBox(height: 20),
        ...timeframes.map((t) {
          final isSelected = selected == t.$1;
          return GestureDetector(
            onTap: () => onSelect(t.$1),
            child: Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: isSelected
                    ? AppTheme.primary.withValues(alpha: 0.12)
                    : AppTheme.surfaceLight,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isSelected
                      ? AppTheme.primary
                      : AppTheme.cardBorder,
                  width: isSelected ? 2 : 1,
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          t.$2,
                          style: TextStyle(
                            color: isSelected
                                ? AppTheme.primary
                                : AppTheme.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          t.$3,
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (isSelected)
                    const Icon(Icons.check_circle,
                        color: AppTheme.primary, size: 20),
                ],
              ),
            ),
          );
        }),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: isLoading ? null : onNext,
          child: isLoading
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Text('Next'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// STEP 2: POSITION
// ─────────────────────────────────────────────────────────────────────────────

class _StepPosition extends StatelessWidget {
  final String creatorUsername;
  final String timeframe;
  final double yesPool;
  final double noPool;
  final String? selected;
  final void Function(String) onSelect;
  final VoidCallback onNext;
  final VoidCallback? onBack;

  const _StepPosition({
    required this.creatorUsername,
    required this.timeframe,
    required this.yesPool,
    required this.noPool,
    required this.selected,
    required this.onSelect,
    required this.onNext,
    this.onBack,
  });

  @override
  Widget build(BuildContext context) {
    final hasPool = yesPool + noPool > 0;
    final total = yesPool + noPool;
    final yesRatio = total > 0 ? yesPool / total : 0.5;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            if (onBack != null)
              IconButton(
                onPressed: onBack,
                icon: const Icon(Icons.arrow_back,
                    color: AppTheme.textSecondary, size: 20),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(),
              ),
            if (onBack != null) const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Choose Position',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  Text(
                    'Will @$creatorUsername\'s score increase or decrease?',
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // Pool sizes
        if (hasPool) ...[
          _PoolBar(yesRatio: yesRatio, yesPool: yesPool, noPool: noPool),
          const SizedBox(height: 16),
        ],

        // YES button
        _PositionButton(
          label: 'Will Increase',
          emoji: '📈',
          color: AppTheme.success,
          pool: yesPool,
          showPool: hasPool,
          isSelected: selected == 'yes',
          onTap: () => onSelect('yes'),
        ),
        const SizedBox(height: 10),

        // NO button
        _PositionButton(
          label: 'Will Decrease',
          emoji: '📉',
          color: AppTheme.danger,
          pool: noPool,
          showPool: hasPool,
          isSelected: selected == 'no',
          onTap: () => onSelect('no'),
        ),

        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: selected != null ? onNext : null,
          child: const Text('Next'),
        ),
      ],
    );
  }
}

class _PositionButton extends StatelessWidget {
  final String label;
  final String emoji;
  final Color color;
  final double pool;
  final bool showPool;
  final bool isSelected;
  final VoidCallback onTap;

  const _PositionButton({
    required this.label,
    required this.emoji,
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
        child: Row(
          children: [
            Text(emoji, style: const TextStyle(fontSize: 24)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                label,
                style: TextStyle(
                  color: isSelected ? color : AppTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (showPool)
              Text(
                '${pool.toStringAsFixed(0)} tokens',
                style: TextStyle(
                  color: color.withValues(alpha: 0.8),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _PoolBar extends StatelessWidget {
  final double yesRatio;
  final double yesPool;
  final double noPool;

  const _PoolBar({
    required this.yesRatio,
    required this.yesPool,
    required this.noPool,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '📈 ${(yesRatio * 100).toStringAsFixed(0)}%',
              style: const TextStyle(
                color: AppTheme.success,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '${(1 - yesRatio) * 100 ~/ 1}% 📉',
              style: const TextStyle(
                color: AppTheme.danger,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 8,
            child: Row(
              children: [
                Expanded(
                  flex: (yesRatio * 100).round(),
                  child: Container(color: AppTheme.success),
                ),
                Expanded(
                  flex: ((1 - yesRatio) * 100).round(),
                  child: Container(color: AppTheme.danger),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              '${yesPool.toStringAsFixed(0)} tokens',
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 11,
              ),
            ),
            Text(
              '${noPool.toStringAsFixed(0)} tokens',
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 11,
              ),
            ),
          ],
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// STEP 3: AMOUNT
// ─────────────────────────────────────────────────────────────────────────────

class _StepAmount extends StatelessWidget {
  final int tokenBalance;
  final double yesPool;
  final double noPool;
  final String position;
  final int selectedAmount;
  final bool useCustom;
  final TextEditingController customController;
  final double estimatedPayout;
  final void Function(int) onQuickAmount;
  final VoidCallback onCustomToggle;
  final VoidCallback onBack;
  final VoidCallback onNext;
  final String? error;

  const _StepAmount({
    required this.tokenBalance,
    required this.yesPool,
    required this.noPool,
    required this.position,
    required this.selectedAmount,
    required this.useCustom,
    required this.customController,
    required this.estimatedPayout,
    required this.onQuickAmount,
    required this.onCustomToggle,
    required this.onBack,
    required this.onNext,
    this.error,
  });

  @override
  Widget build(BuildContext context) {
    const quickAmounts = [10, 25, 50, 100];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              onPressed: onBack,
              icon: const Icon(Icons.arrow_back,
                  color: AppTheme.textSecondary, size: 20),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 8),
            const Text(
              'Choose Amount',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            const Icon(Icons.toll_outlined,
                size: 14, color: AppTheme.textSecondary),
            const SizedBox(width: 4),
            Text(
              'Balance: $tokenBalance tokens',
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 13),
            ),
          ],
        ),
        const SizedBox(height: 20),

        // Quick amounts
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: quickAmounts.map((a) {
            final isSelected = !useCustom && selectedAmount == a;
            return GestureDetector(
              onTap: () => onQuickAmount(a),
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 20, vertical: 12),
                decoration: BoxDecoration(
                  color: isSelected
                      ? AppTheme.primary.withValues(alpha: 0.15)
                      : AppTheme.surfaceLight,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: isSelected
                        ? AppTheme.primary
                        : AppTheme.cardBorder,
                    width: isSelected ? 2 : 1,
                  ),
                ),
                child: Text(
                  '$a',
                  style: TextStyle(
                    color: isSelected
                        ? AppTheme.primary
                        : AppTheme.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 15,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 14),

        // Custom amount
        GestureDetector(
          onTap: onCustomToggle,
          child: TextField(
            controller: customController,
            keyboardType: TextInputType.number,
            onTap: onCustomToggle,
            decoration: InputDecoration(
              labelText: 'Custom amount',
              prefixIcon: const Icon(Icons.edit_outlined,
                  color: AppTheme.textSecondary, size: 18),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: BorderSide(
                  color: useCustom ? AppTheme.primary : AppTheme.cardBorder,
                  width: useCustom ? 2 : 1,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(12),
                borderSide: const BorderSide(
                    color: AppTheme.primary, width: 2),
              ),
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Payout estimate
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
              const Text(
                'Est. payout if you win',
                style: TextStyle(
                    color: AppTheme.textSecondary, fontSize: 13),
              ),
              Text(
                estimatedPayout > 0
                    ? '${estimatedPayout.toStringAsFixed(1)} tokens'
                    : '—',
                style: const TextStyle(
                  color: AppTheme.success,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
              ),
            ],
          ),
        ),

        if (error != null) ...[
          const SizedBox(height: 10),
          Text(error!,
              style: const TextStyle(
                  color: AppTheme.danger, fontSize: 13)),
        ],

        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: onNext,
          child: const Text('Next'),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// STEP 4: CONFIRM
// ─────────────────────────────────────────────────────────────────────────────

class _StepConfirm extends StatelessWidget {
  final String creatorUsername;
  final String timeframe;
  final String position;
  final int amount;
  final double estimatedPayout;
  final bool isNew;
  final bool isSubmitting;
  final String? error;
  final VoidCallback onBack;
  final VoidCallback onConfirm;

  const _StepConfirm({
    required this.creatorUsername,
    required this.timeframe,
    required this.position,
    required this.amount,
    required this.estimatedPayout,
    required this.isNew,
    required this.isSubmitting,
    this.error,
    required this.onBack,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    final positionColor =
        position == 'yes' ? AppTheme.success : AppTheme.danger;
    final positionLabel = position == 'yes' ? '📈 Will Increase' : '📉 Will Decrease';
    final timeframeLabels = {'24h': '24 Hours', '7d': '7 Days', '30d': '30 Days'};

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              onPressed: isSubmitting ? null : onBack,
              icon: const Icon(Icons.arrow_back,
                  color: AppTheme.textSecondary, size: 20),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 8),
            const Text(
              'Confirm Bet',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 20),

        Container(
          padding: const EdgeInsets.all(18),
          decoration: BoxDecoration(
            color: AppTheme.surfaceLight,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.cardBorder),
          ),
          child: Column(
            children: [
              _ConfirmRow('Creator', '@$creatorUsername'),
              const SizedBox(height: 10),
              _ConfirmRow('Timeframe', timeframeLabels[timeframe] ?? timeframe),
              const SizedBox(height: 10),
              _ConfirmRow(
                'Position',
                positionLabel,
                valueColor: positionColor,
              ),
              const SizedBox(height: 10),
              _ConfirmRow('Amount', '$amount tokens'),
              const SizedBox(height: 10),
              _ConfirmRow(
                'Est. payout if win',
                estimatedPayout > 0
                    ? '${estimatedPayout.toStringAsFixed(1)} tokens'
                    : 'N/A',
                valueColor: AppTheme.success,
              ),
              if (isNew) ...[
                const SizedBox(height: 10),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                        color: AppTheme.primary.withValues(alpha: 0.3)),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.new_releases_outlined,
                          size: 14, color: AppTheme.primary),
                      SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          'This opens a new market on this creator',
                          style: TextStyle(
                            color: AppTheme.primary,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),

        if (error != null) ...[
          const SizedBox(height: 12),
          Text(error!,
              style: const TextStyle(
                  color: AppTheme.danger, fontSize: 13)),
        ],

        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: isSubmitting ? null : onConfirm,
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.success,
            minimumSize: const Size(double.infinity, 50),
          ),
          child: isSubmitting
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
}

class _ConfirmRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? valueColor;

  const _ConfirmRow(this.label, this.value, {this.valueColor});

  @override
  Widget build(BuildContext context) => Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 13)),
          Text(
            value,
            style: TextStyle(
              color: valueColor ?? AppTheme.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// SUCCESS STATE
// ─────────────────────────────────────────────────────────────────────────────

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
          const Text(
            'Bet Placed!',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'You\'ll be notified when this market resolves.',
            textAlign: TextAlign.center,
            style: TextStyle(
                color: AppTheme.textSecondary, fontSize: 14, height: 1.5),
          ),
          const SizedBox(height: 28),
          ElevatedButton(
            onPressed: onClose,
            child: const Text('Done'),
          ),
          const SizedBox(height: 8),
        ],
      );
}
