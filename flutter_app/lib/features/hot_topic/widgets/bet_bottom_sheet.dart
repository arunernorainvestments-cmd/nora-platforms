import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/n_glass_sheet.dart';
import '../models/celeb.dart';
import '../providers/hot_topic_providers.dart';

void showHotTopicBetSheet(
  BuildContext context, {
  required CelebWeeklyScore score,
  required List<CelebWeeklyScore> allScores,
  VoidCallback? onBetPlaced,
}) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => HotTopicBetBottomSheet(
      score: score,
      allScores: allScores,
      onBetPlaced: onBetPlaced,
    ),
  );
}

class HotTopicBetBottomSheet extends ConsumerStatefulWidget {
  final CelebWeeklyScore score;
  final List<CelebWeeklyScore> allScores;
  final VoidCallback? onBetPlaced;

  const HotTopicBetBottomSheet({
    super.key,
    required this.score,
    required this.allScores,
    this.onBetPlaced,
  });

  @override
  ConsumerState<HotTopicBetBottomSheet> createState() =>
      _HotTopicBetBottomSheetState();
}

class _HotTopicBetBottomSheetState
    extends ConsumerState<HotTopicBetBottomSheet>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  // Quick Bet state
  String? _simpleDirection;
  int _simpleAmount = 50;
  final _simpleAmountController = TextEditingController();
  bool _simpleUseCustom = false;

  // Weekly Bet state
  String? _weeklyBetType;
  String? _weeklySelectedCelebId;
  int _weeklyAmount = 50;
  final _weeklyAmountController = TextEditingController();
  bool _weeklyUseCustom = false;

  bool _isSubmitting = false;
  bool _success = false;
  String? _error;
  int _tokensRemaining = 0;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    _simpleAmountController.dispose();
    _weeklyAmountController.dispose();
    super.dispose();
  }

  int get _effectiveSimpleAmount =>
      _simpleUseCustom ? (int.tryParse(_simpleAmountController.text) ?? 0) : _simpleAmount;

  int get _effectiveWeeklyAmount =>
      _weeklyUseCustom ? (int.tryParse(_weeklyAmountController.text) ?? 0) : _weeklyAmount;

  Future<void> _placeBet({required bool isSimple}) async {
    final balanceAsync = ref.read(hotTopicTokenBalanceProvider);
    final balance = balanceAsync.valueOrNull ?? 0;
    final amount = isSimple ? _effectiveSimpleAmount : _effectiveWeeklyAmount;

    if (amount < 10) {
      setState(() => _error = 'Minimum wager is 10 tokens');
      return;
    }
    if (amount > balance) {
      setState(() => _error = 'Insufficient tokens (balance: $balance)');
      return;
    }

    setState(() { _isSubmitting = true; _error = null; });

    try {
      final session = Supabase.instance.client.auth.currentSession;
      if (session == null) {
        setState(() { _error = 'Please sign in to place bets'; _isSubmitting = false; });
        return;
      }

      final Map<String, dynamic> body = {
        'bet_category': isSimple ? 'simple' : 'weekly',
        'tokens_wagered': amount,
      };

      if (isSimple) {
        body['celeb_id'] = widget.score.celebId;
        body['simple_direction'] = _simpleDirection;
      } else {
        body['weekly_bet_type'] = _weeklyBetType;
        if (_weeklySelectedCelebId != null) body['celeb_id'] = _weeklySelectedCelebId;
      }

      final res = await Supabase.instance.client.functions.invoke(
        'hot-topic-place-bet',
        body: body,
        headers: { 'Authorization': 'Bearer ${session.accessToken}' },
      );

      if (res.status != 200) {
        final errData = res.data as Map<String, dynamic>?;
        setState(() {
          _error = errData?['error'] as String? ?? 'Failed to place bet';
          _isSubmitting = false;
        });
        return;
      }

      final data = res.data as Map<String, dynamic>;
      setState(() {
        _success = true;
        _tokensRemaining = (data['tokens_remaining'] as num?)?.toInt() ?? 0;
        _isSubmitting = false;
      });

      ref.invalidate(hotTopicTokenBalanceProvider);
      ref.invalidate(currentUserWeeklyBetProvider);
      ref.invalidate(simpleBetCountsProvider);
      widget.onBetPlaced?.call();
    } catch (e) {
      setState(() {
        _error = 'Something went wrong. Please try again.';
        _isSubmitting = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboardPad = MediaQuery.of(context).viewInsets.bottom;
    final week = ref.watch(currentWeekProvider);
    final weeklyBetAsync = ref.watch(currentUserWeeklyBetProvider);
    final balanceAsync = ref.watch(hotTopicTokenBalanceProvider);
    final balance = balanceAsync.valueOrNull ?? 0;

    return NGlassSheet(
      padding: EdgeInsets.fromLTRB(24, 20, 24, 24 + keyboardPad),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const NSheetHandle(),
          const SizedBox(height: 16),

          if (_success)
            _SuccessState(tokensRemaining: _tokensRemaining, onClose: () => Navigator.of(context).pop())
          else ...[
            // Header
            Text(
              widget.score.celebName,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Text(
                  '${widget.score.points} pts',
                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                ),
                if (widget.score.lastDelta != 0) ...[
                  const SizedBox(width: 8),
                  Text(
                    '${widget.score.lastDelta > 0 ? '+' : ''}${widget.score.lastDelta}',
                    style: TextStyle(
                      color: widget.score.lastDelta > 0 ? AppTheme.success : AppTheme.danger,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
                const Spacer(),
                const Icon(Icons.toll_outlined, size: 14, color: AppTheme.textSecondary),
                const SizedBox(width: 4),
                Text(
                  '$balance tokens',
                  style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 16),

            // Tabs
            Container(
              decoration: BoxDecoration(
                color: AppTheme.surfaceLight,
                borderRadius: BorderRadius.circular(10),
              ),
              child: TabBar(
                controller: _tabController,
                indicator: BoxDecoration(
                  color: AppTheme.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                labelColor: Colors.white,
                unselectedLabelColor: AppTheme.textSecondary,
                labelStyle: const TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                dividerColor: Colors.transparent,
                tabs: const [
                  Tab(text: 'Quick Bet'),
                  Tab(text: 'Weekly Bet'),
                ],
              ),
            ),
            const SizedBox(height: 16),

            SizedBox(
              height: 280,
              child: TabBarView(
                controller: _tabController,
                children: [
                  // ── Quick Bet ──────────────────────────────────────────
                  _QuickBetTab(
                    celebName: widget.score.celebName,
                    currentWindow: week.currentWindow,
                    isWindowClosed: false,
                    selectedDirection: _simpleDirection,
                    selectedAmount: _simpleAmount,
                    useCustom: _simpleUseCustom,
                    customController: _simpleAmountController,
                    isSubmitting: _isSubmitting,
                    error: _error,
                    onDirectionSelect: (d) => setState(() => _simpleDirection = d),
                    onAmountSelect: (a) => setState(() { _simpleAmount = a; _simpleUseCustom = false; }),
                    onCustomToggle: () => setState(() => _simpleUseCustom = true),
                    onConfirm: () => _placeBet(isSimple: true),
                  ),

                  // ── Weekly Bet ─────────────────────────────────────────
                  weeklyBetAsync.when(
                    loading: () => const Center(child: CircularProgressIndicator()),
                    error: (_, __) => const Center(child: Text('Could not load bet status', style: TextStyle(color: AppTheme.textSecondary))),
                    data: (existingBet) => _WeeklyBetTab(
                      allScores: widget.allScores,
                      existingBet: existingBet,
                      isResolved: week.isResolved,
                      selectedBetType: _weeklyBetType,
                      selectedCelebId: _weeklySelectedCelebId,
                      selectedAmount: _weeklyAmount,
                      useCustom: _weeklyUseCustom,
                      customController: _weeklyAmountController,
                      isSubmitting: _isSubmitting,
                      error: _error,
                      onBetTypeSelect: (t) => setState(() => _weeklyBetType = t),
                      onCelebSelect: (id) => setState(() => _weeklySelectedCelebId = id),
                      onAmountSelect: (a) => setState(() { _weeklyAmount = a; _weeklyUseCustom = false; }),
                      onCustomToggle: () => setState(() => _weeklyUseCustom = true),
                      onConfirm: () => _placeBet(isSimple: false),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// QUICK BET TAB
// ─────────────────────────────────────────────────────────────────────────────

class _QuickBetTab extends StatelessWidget {
  final String celebName;
  final String currentWindow;
  final bool isWindowClosed;
  final String? selectedDirection;
  final int selectedAmount;
  final bool useCustom;
  final TextEditingController customController;
  final bool isSubmitting;
  final String? error;
  final void Function(String) onDirectionSelect;
  final void Function(int) onAmountSelect;
  final VoidCallback onCustomToggle;
  final VoidCallback onConfirm;

  const _QuickBetTab({
    required this.celebName,
    required this.currentWindow,
    required this.isWindowClosed,
    required this.selectedDirection,
    required this.selectedAmount,
    required this.useCustom,
    required this.customController,
    required this.isSubmitting,
    this.error,
    required this.onDirectionSelect,
    required this.onAmountSelect,
    required this.onCustomToggle,
    required this.onConfirm,
  });

  @override
  Widget build(BuildContext context) {
    if (isWindowClosed) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.schedule_rounded, size: 40, color: AppTheme.textSecondary.withValues(alpha: 0.5)),
              const SizedBox(height: 12),
              const Text(
                'This scoring window has closed.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
              ),
              const SizedBox(height: 4),
              const Text(
                'Betting opens again at the next scoring window.',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    final windowLabel = currentWindow.endsWith('-AM') ? 'AM window' : 'PM window';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            'Will $celebName trend UP or DOWN this $windowLabel?',
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 12),

          // Direction buttons
          _DirectionButton(
            label: 'Trending Up',
            emoji: '📈',
            color: AppTheme.success,
            isSelected: selectedDirection == 'up',
            onTap: () => onDirectionSelect('up'),
          ),
          const SizedBox(height: 8),
          _DirectionButton(
            label: 'Trending Down',
            emoji: '📉',
            color: AppTheme.danger,
            isSelected: selectedDirection == 'down',
            onTap: () => onDirectionSelect('down'),
          ),
          const SizedBox(height: 12),

          // Amount chips
          _AmountChips(
            selected: selectedAmount,
            useCustom: useCustom,
            customController: customController,
            onSelect: onAmountSelect,
            onCustomToggle: onCustomToggle,
          ),

          if (error != null) ...[
            const SizedBox(height: 8),
            Text(error!, style: const TextStyle(color: AppTheme.danger, fontSize: 13)),
          ],
          const SizedBox(height: 12),

          ElevatedButton(
            onPressed: (selectedDirection == null || isSubmitting) ? null : onConfirm,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              minimumSize: const Size(double.infinity, 46),
            ),
            child: isSubmitting
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Place Quick Bet', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class _DirectionButton extends StatelessWidget {
  final String label;
  final String emoji;
  final Color color;
  final bool isSelected;
  final VoidCallback onTap;

  const _DirectionButton({
    required this.label,
    required this.emoji,
    required this.color,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: isSelected ? color.withValues(alpha: 0.12) : AppTheme.surfaceLight,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: isSelected ? color : AppTheme.cardBorder,
              width: isSelected ? 2 : 1,
            ),
          ),
          child: Row(
            children: [
              Text(emoji, style: const TextStyle(fontSize: 22)),
              const SizedBox(width: 10),
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? color : AppTheme.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              if (isSelected) ...[
                const Spacer(),
                Icon(Icons.check_circle, color: color, size: 18),
              ],
            ],
          ),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// WEEKLY BET TAB
// ─────────────────────────────────────────────────────────────────────────────

class _WeeklyBetTab extends StatelessWidget {
  final List<CelebWeeklyScore> allScores;
  final WeeklyBet? existingBet;
  final bool isResolved;
  final String? selectedBetType;
  final String? selectedCelebId;
  final int selectedAmount;
  final bool useCustom;
  final TextEditingController customController;
  final bool isSubmitting;
  final String? error;
  final void Function(String) onBetTypeSelect;
  final void Function(String?) onCelebSelect;
  final void Function(int) onAmountSelect;
  final VoidCallback onCustomToggle;
  final VoidCallback onConfirm;

  const _WeeklyBetTab({
    required this.allScores,
    required this.existingBet,
    required this.isResolved,
    required this.selectedBetType,
    required this.selectedCelebId,
    required this.selectedAmount,
    required this.useCustom,
    required this.customController,
    required this.isSubmitting,
    this.error,
    required this.onBetTypeSelect,
    required this.onCelebSelect,
    required this.onAmountSelect,
    required this.onCustomToggle,
    required this.onConfirm,
  });

  static const _betTypes = [
    ('person_of_week', '👑 Person of the Week', 'Highest points at week end'),
    ('top_riser',      '🚀 Top Riser',          'Biggest score gain this week'),
    ('big_boo',        '💀 Big Boo',            'Lowest points at week end'),
    ('top_5',          '🔥 Top 5',              'Finishing in the top 5'),
  ];

  @override
  Widget build(BuildContext context) {
    if (isResolved) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(16),
          child: Text(
            'Weekly betting is closed.\nResults are being tallied.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
          ),
        ),
      );
    }

    if (existingBet != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.check_circle_outline, color: AppTheme.success, size: 40),
              const SizedBox(height: 12),
              const Text(
                "You've already placed your weekly bet.",
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.w600),
              ),
              const SizedBox(height: 6),
              Text(
                'Come back next week for a fresh bet!',
                textAlign: TextAlign.center,
                style: TextStyle(color: AppTheme.textSecondary.withValues(alpha: 0.8), fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    final needsCelebPicker = selectedBetType == 'person_of_week' || selectedBetType == 'top_riser';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Bet type selector
          for (final (type, label, subtitle) in _betTypes) ...[
            _BetTypeRow(
              label: label,
              subtitle: subtitle,
              isSelected: selectedBetType == type,
              onTap: () {
                onBetTypeSelect(type);
                // Clear celeb selection if changing bet type
                if (type != 'person_of_week' && type != 'top_riser') onCelebSelect(null);
              },
            ),
            const SizedBox(height: 6),
          ],

          // Celeb picker for person_of_week / top_riser
          if (needsCelebPicker) ...[
            const SizedBox(height: 4),
            Text(
              selectedBetType == 'person_of_week' ? 'Pick who will be #1:' : 'Pick the biggest riser:',
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: AppTheme.surfaceLight,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.cardBorder),
              ),
              child: DropdownButton<String>(
                value: selectedCelebId,
                dropdownColor: AppTheme.surface,
                isExpanded: true,
                underline: const SizedBox.shrink(),
                hint: const Text('Select celebrity', style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
                style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
                items: allScores.map((s) => DropdownMenuItem(
                  value: s.celebId,
                  child: Text(s.celebName, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13)),
                )).toList(),
                onChanged: (id) => onCelebSelect(id),
              ),
            ),
            const SizedBox(height: 8),
          ],

          // Amount chips
          _AmountChips(
            selected: selectedAmount,
            useCustom: useCustom,
            customController: customController,
            onSelect: onAmountSelect,
            onCustomToggle: onCustomToggle,
          ),

          if (error != null) ...[
            const SizedBox(height: 8),
            Text(error!, style: const TextStyle(color: AppTheme.danger, fontSize: 13)),
          ],
          const SizedBox(height: 12),

          ElevatedButton(
            onPressed: (selectedBetType == null || (needsCelebPicker && selectedCelebId == null) || isSubmitting) ? null : onConfirm,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              minimumSize: const Size(double.infinity, 46),
            ),
            child: isSubmitting
                ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Text('Place Weekly Bet', style: TextStyle(fontWeight: FontWeight.w700)),
          ),
        ],
      ),
    );
  }
}

class _BetTypeRow extends StatelessWidget {
  final String label;
  final String subtitle;
  final bool isSelected;
  final VoidCallback onTap;

  const _BetTypeRow({
    required this.label,
    required this.subtitle,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? AppTheme.primary.withValues(alpha: 0.1) : AppTheme.surfaceLight,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? AppTheme.primary : AppTheme.cardBorder,
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
                      label,
                      style: TextStyle(
                        color: isSelected ? AppTheme.primary : AppTheme.textPrimary,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                const Icon(Icons.check_circle, color: AppTheme.primary, size: 16),
            ],
          ),
        ),
      );
}

// ─────────────────────────────────────────────────────────────────────────────
// SHARED: AMOUNT CHIPS
// ─────────────────────────────────────────────────────────────────────────────

class _AmountChips extends StatelessWidget {
  final int selected;
  final bool useCustom;
  final TextEditingController customController;
  final void Function(int) onSelect;
  final VoidCallback onCustomToggle;

  const _AmountChips({
    required this.selected,
    required this.useCustom,
    required this.customController,
    required this.onSelect,
    required this.onCustomToggle,
  });

  @override
  Widget build(BuildContext context) {
    const quickAmounts = [10, 25, 50, 100];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Tokens to wager:', style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          children: quickAmounts.map((a) {
            final isSelected = !useCustom && selected == a;
            return GestureDetector(
              onTap: () => onSelect(a),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                decoration: BoxDecoration(
                  color: isSelected ? AppTheme.primary.withValues(alpha: 0.15) : AppTheme.surfaceLight,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: isSelected ? AppTheme.primary : AppTheme.cardBorder,
                    width: isSelected ? 2 : 1,
                  ),
                ),
                child: Text(
                  '$a',
                  style: TextStyle(
                    color: isSelected ? AppTheme.primary : AppTheme.textPrimary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: customController,
          keyboardType: TextInputType.number,
          onTap: onCustomToggle,
          style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
          decoration: InputDecoration(
            labelText: 'Custom amount',
            labelStyle: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: BorderSide(
                color: useCustom ? AppTheme.primary : AppTheme.cardBorder,
                width: useCustom ? 2 : 1,
              ),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(10),
              borderSide: const BorderSide(color: AppTheme.primary, width: 2),
            ),
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SUCCESS STATE
// ─────────────────────────────────────────────────────────────────────────────

class _SuccessState extends StatelessWidget {
  final int tokensRemaining;
  final VoidCallback onClose;

  const _SuccessState({required this.tokensRemaining, required this.onClose});

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 16),
          const Center(child: Icon(Icons.check_circle_outline, size: 56, color: AppTheme.success)),
          const SizedBox(height: 16),
          const Text(
            'Bet Placed!',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'Balance: $tokensRemaining tokens remaining',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 14),
          ),
          const SizedBox(height: 28),
          ElevatedButton(onPressed: onClose, child: const Text('Done')),
        ],
      );
}
