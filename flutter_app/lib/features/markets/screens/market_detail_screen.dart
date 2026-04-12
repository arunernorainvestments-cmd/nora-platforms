import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/markets_providers.dart';

// ───────────────────────────────────────────────────────────────────────��─────
// SCREEN
// ─────────────────────────────────────────────────────────────────────────────

class MarketDetailScreen extends ConsumerStatefulWidget {
  final String marketId;
  const MarketDetailScreen({super.key, required this.marketId});

  @override
  ConsumerState<MarketDetailScreen> createState() =>
      _MarketDetailScreenState();
}

class _MarketDetailScreenState extends ConsumerState<MarketDetailScreen> {
  bool _drawerOpen = false;
  String _selectedPosition = 'above'; // 'above' | 'below'

  void _openDrawer(String position) {
    debugPrint('drawer opened: position=$position drawerOpen=true');
    setState(() {
      _selectedPosition = position;
      _drawerOpen = true;
    });
  }

  void _closeDrawer() => setState(() => _drawerOpen = false);

  Future<void> _confirmBet(MarketDetail market, int amount) async {
    final userId = Supabase.instance.client.auth.currentUser?.id;
    if (userId == null) throw Exception('Not logged in');

    final myPool =
        _selectedPosition == 'above' ? market.yesPool : market.noPool;
    final total = market.totalPool;
    final denominator = myPool + amount;
    final payout = denominator > 0
        ? ((amount / denominator) * (total + amount) * 0.90).floor()
        : amount;

    await Supabase.instance.client.from('bets').insert({
      'market_id': market.id,
      'user_id': userId,
      'position': _selectedPosition == 'above' ? 'yes' : 'no',
      'amount': amount,
      'potential_payout': payout > 0 ? payout : null,
      'status': 'active',
    });

    if (!mounted) return;
    _closeDrawer();
    ref.invalidate(marketDetailProvider(widget.marketId));
    ref.invalidate(tokenBalanceProvider);
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Bet placed!'),
        behavior: SnackBarBehavior.floating,
        backgroundColor: AppTheme.success,
      ),
    );
  }

  AppBar _buildAppBar(String title) => AppBar(
        backgroundColor: AppTheme.background,
        surfaceTintColor: Colors.transparent,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: AppTheme.textPrimary),
          onPressed: () => context.pop(),
        ),
        title: Text(
          title,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      );

  @override
  Widget build(BuildContext context) {
    final detailAsync = ref.watch(marketDetailProvider(widget.marketId));
    final screenWidth = MediaQuery.of(context).size.width;
    final drawerWidth = screenWidth * 0.88;

    return detailAsync.when(
      loading: () => Scaffold(
        backgroundColor: AppTheme.background,
        appBar: _buildAppBar(''),
        body: const Center(child: CircularProgressIndicator()),
      ),
      error: (e, _) => Scaffold(
        backgroundColor: AppTheme.background,
        appBar: _buildAppBar('Market'),
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.wifi_off_rounded,
                  size: 48, color: AppTheme.textSecondary),
              const SizedBox(height: 16),
              const Text('Failed to load market',
                  style: TextStyle(color: AppTheme.textSecondary)),
              const SizedBox(height: 16),
              TextButton(
                onPressed: () =>
                    ref.invalidate(marketDetailProvider(widget.marketId)),
                child: const Text('Retry',
                    style: TextStyle(color: AppTheme.primary)),
              ),
            ],
          ),
        ),
      ),
      data: (market) => Scaffold(
        backgroundColor: AppTheme.background,
        appBar: _buildAppBar(market.title),
        body: Stack(
          fit: StackFit.expand,
          children: [
            // ── Main content + bottom bar ─────────────────────────────────
            Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 100),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _CreatorHeader(market: market),
                        const SizedBox(height: 16),
                        _ScoreSection(market: market),
                        const SizedBox(height: 12),
                        _CountdownTimer(
                          endAt: market.endAt,
                          status: market.status,
                          resolvedAt: market.resolvedAt,
                        ),
                        const SizedBox(height: 12),
                        _PoolSection(market: market),
                      ],
                    ),
                  ),
                ),
                _BottomBar(
                  market: market,
                  onAbove: () => _openDrawer('above'),
                  onBelow: () => _openDrawer('below'),
                ),
              ],
            ),

            // ── Dim overlay when drawer is open ───────────────────────────
            if (_drawerOpen)
              GestureDetector(
                onTap: _closeDrawer,
                child: Container(
                  color: Colors.black.withValues(alpha: 0.55),
                ),
              ),

            // ── Betting drawer — slides in from right ─────────────────────
            Align(
              alignment: Alignment.centerRight,
              child: AnimatedSlide(
                offset: _drawerOpen ? Offset.zero : const Offset(1, 0),
                duration: const Duration(milliseconds: 260),
                curve: Curves.easeInOut,
                child: SizedBox(
                  width: drawerWidth,
                  height: double.infinity,
                  child: _BettingDrawer(
                    market: market,
                    selectedPosition: _selectedPosition,
                    onPositionChange: (p) =>
                        setState(() => _selectedPosition = p),
                    onClose: _closeDrawer,
                    onConfirm: (amount) => _confirmBet(market, amount),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ────────────────���──────────────────────────────────────────────────────���─────
// CREATOR HEADER
// ─────────────────────────────────────────────────────────────────────────────

class _CreatorHeader extends StatelessWidget {
  final MarketDetail market;
  const _CreatorHeader({required this.market});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        CircleAvatar(
          radius: 26,
          backgroundColor: AppTheme.primary.withValues(alpha: 0.2),
          child: Text(
            market.creatorUsername.isNotEmpty
                ? market.creatorUsername[0].toUpperCase()
                : '?',
            style: const TextStyle(
              color: AppTheme.primary,
              fontSize: 20,
              fontWeight: FontWeight.bold,
            ),
          ),
        ),
        const SizedBox(width: 14),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '@${market.creatorUsername}',
                style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                ),
              ),
              if (market.primaryPlatform != null) ...[
                const SizedBox(height: 4),
                Row(
                  children: [
                    _PlatformBadge(platform: market.primaryPlatform!),
                    if (market.primaryPlatformUsername != null) ...[
                      const SizedBox(width: 6),
                      Text(
                        '@${market.primaryPlatformUsername}',
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

// ───────────────────────────────���────────────────────────────────���────────────
// SCORE SECTION
// ───────────────────────────────────────���─────────────────────────────��───────

class _ScoreSection extends StatelessWidget {
  final MarketDetail market;
  const _ScoreSection({required this.market});

  @override
  Widget build(BuildContext context) {
    final score = market.displayScore;
    final scoreText = score != null
        ? score.toStringAsFixed(1)
        : '--';

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Live badge (shown above score when live)
          if (market.isLive) ...[
            const _LiveBadge(),
            const SizedBox(height: 10),
          ],

          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              // Current display score
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'Current Score',
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      scoreText,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 48,
                        fontWeight: FontWeight.bold,
                        height: 1.0,
                      ),
                    ),
                    if (market.isLive && market.liveViewerCount > 0) ...[
                      const SizedBox(height: 4),
                      Text(
                        '${market.liveViewerCount} watching',
                        style: const TextStyle(
                          color: AppTheme.danger,
                          fontSize: 12,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              // Target score
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  const Text(
                    'Target',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    market.formattedTarget,
                    style: const TextStyle(
                      color: AppTheme.primary,
                      fontSize: 22,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const Text(
                    'followers at open',
                    style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// COUNTDOWN TIMER
// ──────────────────────────────────────��──────────────────────────────────────

class _CountdownTimer extends StatefulWidget {
  final DateTime endAt;
  final String status;
  final DateTime? resolvedAt;

  const _CountdownTimer({
    required this.endAt,
    required this.status,
    this.resolvedAt,
  });

  @override
  State<_CountdownTimer> createState() => _CountdownTimerState();
}

class _CountdownTimerState extends State<_CountdownTimer> {
  late Timer _timer;
  late Duration _remaining;

  @override
  void initState() {
    super.initState();
    _remaining = _calc();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _remaining = _calc());
    });
  }

  Duration _calc() {
    final d = widget.endAt.difference(DateTime.now());
    return d.isNegative ? Duration.zero : d;
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  String _format(Duration d) {
    if (d.inSeconds <= 0) return 'Ended';
    final days = d.inDays;
    final hours = d.inHours % 24;
    final minutes = d.inMinutes % 60;
    final seconds = d.inSeconds % 60;
    if (days > 0) return '${days}d ${hours}h ${minutes}m';
    if (hours > 0) return '${hours}h ${minutes}m ${seconds}s';
    if (minutes > 0) return '${minutes}m ${seconds}s';
    return '${seconds}s';
  }

  // Returns (icon, label, valueText, valueColor) for the current state.
  ({IconData icon, Color iconColor, String label, String value, Color valueColor})
      get _display {
    final status = widget.status;

    if (status == 'voided') {
      return (
        icon: Icons.cancel_outlined,
        iconColor: AppTheme.textSecondary,
        label: 'Market voided',
        value: 'Refunded',
        valueColor: AppTheme.textSecondary,
      );
    }

    if (status == 'resolved') {
      final at = widget.resolvedAt;
      final timeStr = at != null
          ? '${at.toLocal().hour.toString().padLeft(2, '0')}:'
            '${at.toLocal().minute.toString().padLeft(2, '0')}'
          : '';
      return (
        icon: Icons.check_circle_outline,
        iconColor: AppTheme.success,
        label: 'Resolved',
        value: timeStr.isNotEmpty ? 'at $timeStr' : 'complete',
        valueColor: AppTheme.success,
      );
    }

    // status == 'open' (or any unexpected value)
    final ended = _remaining.inSeconds <= 0;
    if (ended) {
      return (
        icon: Icons.timer_off_outlined,
        iconColor: AppTheme.danger,
        label: 'Resolving...',
        value: '',
        valueColor: AppTheme.danger,
      );
    }

    return (
      icon: Icons.timer_outlined,
      iconColor: AppTheme.primary,
      label: 'Closes in',
      value: _format(_remaining),
      valueColor: AppTheme.textPrimary,
    );
  }

  @override
  Widget build(BuildContext context) {
    final d = _display;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
      decoration: BoxDecoration(
        color: AppTheme.surfaceLight,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Row(
        children: [
          Icon(d.icon, size: 18, color: d.iconColor),
          const SizedBox(width: 10),
          Text(
            d.label,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
          const Spacer(),
          if (d.value.isNotEmpty)
            Text(
              d.value,
              style: TextStyle(
                color: d.valueColor,
                fontSize: 20,
                fontWeight: FontWeight.bold,
                letterSpacing: 0.5,
              ),
            ),
        ],
      ),
    );
  }
}

// ───────────────────────────────────────────────���─────────────────────────────
// POOL SECTION
// ──────────────────────────────────��──────────────────────────────────────────

class _PoolSection extends StatelessWidget {
  final MarketDetail market;
  const _PoolSection({required this.market});

  @override
  Widget build(BuildContext context) {
    final total = market.totalPool;
    final aboveRatio = total > 0 ? market.yesPool / total : 0.5;

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '📈 Above  ${(aboveRatio * 100).toStringAsFixed(0)}%',
                style: const TextStyle(
                  color: AppTheme.success,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Text(
                '${(1 - aboveRatio) * 100 ~/ 1}%  Below 📉',
                style: const TextStyle(
                  color: AppTheme.danger,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: SizedBox(
              height: 10,
              child: Row(
                children: [
                  Expanded(
                    flex: (aboveRatio * 100).round().clamp(1, 99),
                    child: Container(color: AppTheme.success),
                  ),
                  Expanded(
                    flex: ((1 - aboveRatio) * 100).round().clamp(1, 99),
                    child: Container(color: AppTheme.danger),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                '${market.yesPool.toStringAsFixed(0)} tokens',
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 12),
              ),
              Text(
                '${total.toStringAsFixed(0)} total',
                style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w600),
              ),
              Text(
                '${market.noPool.toStringAsFixed(0)} tokens',
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────────���─
// BOTTOM BAR
// ──────────────────────────────────────���──────────────────────────────────────

class _BottomBar extends StatefulWidget {
  final MarketDetail market;
  final VoidCallback onAbove;
  final VoidCallback onBelow;
  const _BottomBar({
    required this.market,
    required this.onAbove,
    required this.onBelow,
  });

  @override
  State<_BottomBar> createState() => _BottomBarState();
}

class _BottomBarState extends State<_BottomBar> {
  late Timer _timer;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  bool get _isBettingBlocked {
    if (widget.market.status != 'open') return true;
    final secsLeft =
        widget.market.endAt.difference(DateTime.now().toUtc()).inSeconds;
    return secsLeft <= 15;
  }

  String get _blockedMessage {
    if (widget.market.status != 'open') {
      return 'Market ${widget.market.status}';
    }
    return 'Betting closed — market ending';
  }

  @override
  Widget build(BuildContext context) {
    final bottomPad = MediaQuery.of(context).padding.bottom;
    final blocked = _isBettingBlocked;
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        border: Border(top: BorderSide(color: AppTheme.cardBorder)),
      ),
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottomPad),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (blocked) ...[
            Text(
              _blockedMessage,
              style: const TextStyle(
                color: AppTheme.danger,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
          ],
          Row(
            children: [
              Expanded(
                child: ElevatedButton(
                  onPressed: blocked ? null : widget.onAbove,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.success,
                    disabledBackgroundColor:
                        AppTheme.success.withValues(alpha: 0.3),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text(
                    '📈 Above',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton(
                  onPressed: blocked ? null : widget.onBelow,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.danger,
                    disabledBackgroundColor:
                        AppTheme.danger.withValues(alpha: 0.3),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: const Text(
                    '📉 Below',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────���───────────────────────────────────
// BETTING DRAWER
// ──────────────────────────���────────────────────────��─────────────────────────

class _BettingDrawer extends ConsumerStatefulWidget {
  final MarketDetail market;
  final String selectedPosition;
  final void Function(String) onPositionChange;
  final VoidCallback onClose;
  final Future<void> Function(int amount) onConfirm;

  const _BettingDrawer({
    required this.market,
    required this.selectedPosition,
    required this.onPositionChange,
    required this.onClose,
    required this.onConfirm,
  });

  @override
  ConsumerState<_BettingDrawer> createState() => _BettingDrawerState();
}

class _BettingDrawerState extends ConsumerState<_BettingDrawer> {
  final _controller = TextEditingController(text: '10');
  int _amount = 10;
  bool _isSubmitting = false;
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  bool get _isBettingBlocked {
    if (widget.market.status != 'open') return true;
    final secsLeft =
        widget.market.endAt.difference(DateTime.now().toUtc()).inSeconds;
    return secsLeft <= 15;
  }

  String get _blockedMessage {
    if (widget.market.status != 'open') {
      return 'Market ${widget.market.status}';
    }
    return 'Betting closed — market ending';
  }

  int get _payout {
    if (_amount <= 0) return 0;
    final myPool = widget.selectedPosition == 'above'
        ? widget.market.yesPool
        : widget.market.noPool;
    final total = widget.market.totalPool;
    final denominator = myPool + _amount;
    if (denominator == 0) return _amount;
    return ((_amount / denominator) * (total + _amount) * 0.90).floor();
  }

  Future<void> _handleConfirm() async {
    if (_isBettingBlocked) {
      setState(() => _error = _blockedMessage);
      return;
    }
    if (_amount <= 0) {
      setState(() => _error = 'Enter a valid amount');
      return;
    }
    setState(() {
      _isSubmitting = true;
      _error = null;
    });
    try {
      await widget.onConfirm(_amount);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().contains('Insufficient token balance')
            ? 'Insufficient token balance'
            : 'Failed to place bet. Try again.';
      });
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokenBalanceAsync = ref.watch(tokenBalanceProvider);
    final tokenBalance = tokenBalanceAsync.valueOrNull ?? 0;
    final isAbove = widget.selectedPosition == 'above';
    final closesAt = widget.market.endAt;
    final closesStr =
        '${closesAt.hour.toString().padLeft(2, '0')}:${closesAt.minute.toString().padLeft(2, '0')}';
    final bottomPad = MediaQuery.of(context).padding.bottom;

    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        boxShadow: [
          BoxShadow(
            color: Colors.black45,
            blurRadius: 20,
            offset: Offset(-4, 0),
          ),
        ],
      ),
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            20,
            16,
            20,
            16 + MediaQuery.of(context).viewInsets.bottom + bottomPad,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Row(
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '@${widget.market.creatorUsername}',
                          style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Text(
                          'Closes at $closesStr',
                          style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    onPressed: widget.onClose,
                    icon: const Icon(Icons.close,
                        color: AppTheme.textSecondary, size: 20),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Position selector
              Row(
                children: [
                  Expanded(
                    child: GestureDetector(
                      onTap: () => widget.onPositionChange('above'),
                      child: _PositionChip(
                        label: '📈 Above',
                        color: AppTheme.success,
                        selected: isAbove,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: GestureDetector(
                      onTap: () => widget.onPositionChange('below'),
                      child: _PositionChip(
                        label: '📉 Below',
                        color: AppTheme.danger,
                        selected: !isAbove,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),

              // Token balance
              Row(
                children: [
                  const Icon(Icons.toll_outlined,
                      size: 14, color: AppTheme.textSecondary),
                  const SizedBox(width: 4),
                  Text(
                    'Balance: $tokenBalance tokens',
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 12),
                  ),
                ],
              ),
              const SizedBox(height: 10),

              // Amount input
              TextField(
                controller: _controller,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                style: const TextStyle(
                    color: AppTheme.textPrimary, fontSize: 16),
                decoration: InputDecoration(
                  labelText: 'Token amount',
                  prefixIcon: const Icon(Icons.toll_outlined,
                      color: AppTheme.textSecondary, size: 18),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: const BorderSide(color: AppTheme.cardBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide:
                        const BorderSide(color: AppTheme.primary, width: 2),
                  ),
                  errorText: _error,
                ),
                onChanged: (v) {
                  final parsed = int.tryParse(v) ?? 0;
                  setState(() {
                    _amount = parsed;
                    _error = null;
                  });
                },
              ),
              const SizedBox(height: 12),

              // Estimated payout
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 12),
                decoration: BoxDecoration(
                  color: AppTheme.surfaceLight,
                  borderRadius: BorderRadius.circular(10),
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
                      _payout > 0 ? '$_payout tokens' : '—',
                      style: const TextStyle(
                        color: AppTheme.success,
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 16),

              // Timeline
              _MarketTimeline(
                openedAt: widget.market.createdAt,
                closesAt: widget.market.endAt,
              ),
              const SizedBox(height: 12),

              // Market identifier
              if (widget.market.identifier != null)
                _MarketIdentifierRow(identifier: widget.market.identifier!),
              if (widget.market.identifier != null) const SizedBox(height: 16),

              // Confirm button
              if (_isBettingBlocked)
                Container(
                  width: double.infinity,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  decoration: BoxDecoration(
                    color: AppTheme.surfaceLight,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppTheme.danger.withValues(alpha: 0.4)),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    _blockedMessage,
                    style: const TextStyle(
                      color: AppTheme.danger,
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                )
              else
                ElevatedButton(
                  onPressed: _isSubmitting ? null : _handleConfirm,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.primary,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12)),
                  ),
                  child: _isSubmitting
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white),
                        )
                      : const Text(
                          'Confirm Bet',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PositionChip extends StatelessWidget {
  final String label;
  final Color color;
  final bool selected;
  const _PositionChip(
      {required this.label, required this.color, required this.selected});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      decoration: BoxDecoration(
        color: selected ? color.withValues(alpha: 0.18) : AppTheme.surfaceLight,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: selected ? color : AppTheme.cardBorder,
          width: selected ? 2 : 1,
        ),
      ),
      alignment: Alignment.center,
      child: Text(
        label,
        style: TextStyle(
          color: selected ? color : AppTheme.textSecondary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

// ───────────────────────────────────────────────────────────────────────���─────
// PLATFORM BADGE
// ─────────────────────────────────────────────────────────────────────────��───

class _PlatformBadge extends StatelessWidget {
  final String platform;
  const _PlatformBadge({required this.platform});

  static const _info = {
    'youtube': ('YT', Color(0xFFFF0000)),
    'twitch': ('Twitch', Color(0xFF9146FF)),
    'tiktok': ('TT', Color(0xFFFF004F)),
    'instagram': ('IG', Color(0xFFE1306C)),
    'x': ('X', Color(0xFF1DA1F2)),
    'kick': ('Kick', Color(0xFF53FC18)),
  };

  @override
  Widget build(BuildContext context) {
    final info = _info[platform];
    if (info == null) return const SizedBox.shrink();
    final label = info.$1;
    final color = info.$2;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 11,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────��───────────────────────────────
// LIVE BADGE — pulsing red dot
// ──────────────────────────────────────────────────────────────────────────��──

// ─────────────────────────────────────────────────────────────────────────────
// MARKET TIMELINE
// ─────────────────────────────────────────────────────────────────────────────

class _MarketTimeline extends StatelessWidget {
  final DateTime? openedAt;
  final DateTime closesAt;

  const _MarketTimeline({this.openedAt, required this.closesAt});

  String _fmt(DateTime dt) {
    final local = dt.toLocal();
    const months = [
      '', 'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'
    ];
    final hh = local.hour.toString().padLeft(2, '0');
    final mm = local.minute.toString().padLeft(2, '0');
    return '${local.day} ${months[local.month]} · $hh:$mm';
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surfaceLight,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: const BoxDecoration(
                  color: AppTheme.success,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                'Market open',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
              const Spacer(),
              Text(
                openedAt != null ? _fmt(openedAt!) : '—',
                style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 4, top: 2, bottom: 2),
            child: Row(
              children: [
                Container(width: 2, height: 16, color: AppTheme.cardBorder),
              ],
            ),
          ),
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: AppTheme.textSecondary, width: 2),
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                'Market closes',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
              ),
              const Spacer(),
              Text(
                _fmt(closesAt),
                style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 12,
                    fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARKET IDENTIFIER ROW
// ─────────────────────────────────────────────────────────────────────────────

class _MarketIdentifierRow extends StatelessWidget {
  final String identifier;
  const _MarketIdentifierRow({required this.identifier});

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        const Text(
          'Market',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
        ),
        Text(
          identifier,
          style: const TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 11,
            fontWeight: FontWeight.w500,
            letterSpacing: 0.8,
            fontFamily: 'Courier New',
          ),
        ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// LIVE BADGE — pulsing red dot
// ─────────────────────────────────────────────────────────────────────────────

class _LiveBadge extends StatefulWidget {
  const _LiveBadge();

  @override
  State<_LiveBadge> createState() => _LiveBadgeState();
}

class _LiveBadgeState extends State<_LiveBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fade;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    )..repeat(reverse: true);
    _fade = Tween<double>(begin: 0.35, end: 1.0).animate(
      CurvedAnimation(parent: _controller, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedBuilder(
          animation: _fade,
          builder: (_, __) => Opacity(
            opacity: _fade.value,
            child: Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: AppTheme.danger,
                shape: BoxShape.circle,
              ),
            ),
          ),
        ),
        const SizedBox(width: 5),
        const Text(
          'Live Now',
          style: TextStyle(
            color: AppTheme.danger,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}
