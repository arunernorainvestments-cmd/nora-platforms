import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../models/promotion_banner.dart';
import '../providers/banner_providers.dart';

// ─────────────────────────────────────────────────────────────────────────────
// PromotionFlashBanner
// Wraps any child and shows a slide-in banner from the top for 4 seconds
// whenever a new Universe or (eligible) Galaxy promotion_banner is inserted.
// Rendered inside MainShell so it appears on all screens.
// ─────────────────────────────────────────────────────────────────────────────

class PromotionFlashBanner extends ConsumerStatefulWidget {
  final Widget child;
  const PromotionFlashBanner({super.key, required this.child});

  @override
  ConsumerState<PromotionFlashBanner> createState() =>
      _PromotionFlashBannerState();
}

class _PromotionFlashBannerState extends ConsumerState<PromotionFlashBanner>
    with SingleTickerProviderStateMixin {
  late final AnimationController _animController;
  late final Animation<Offset> _slideAnim;

  final List<PromotionBanner> _queue = [];
  PromotionBanner? _current;
  Timer? _dismissTimer;
  RealtimeChannel? _channel;
  Set<String> _userCategories = {};

  @override
  void initState() {
    super.initState();
    _animController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _slideAnim = Tween<Offset>(
      begin: const Offset(0, -1),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _animController, curve: Curves.easeOutBack));

    _subscribeRealtime();
  }

  void _subscribeRealtime() {
    _channel = Supabase.instance.client
        .channel('flash_banner_promotions')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'promotion_banners',
          callback: (payload) {
            final row = payload.newRecord;
            if (row.isEmpty) return;
            try {
              final banner = PromotionBanner.fromJson(row);
              if (!banner.isActive) return;
              if (_shouldShowBanner(banner)) _enqueue(banner);
            } catch (_) {}
          },
        )
        .subscribe();
  }

  bool _shouldShowBanner(PromotionBanner banner) {
    if (banner.isUniverse) return true;
    if (banner.isGalaxy && banner.category != null) {
      return _userCategories.contains(banner.category);
    }
    return false;
  }

  void _enqueue(PromotionBanner banner) {
    _queue.add(banner);
    if (_current == null) _showNext();
  }

  void _showNext() {
    if (_queue.isEmpty) return;
    setState(() => _current = _queue.removeAt(0));
    _animController.forward(from: 0);
    _dismissTimer?.cancel();
    _dismissTimer = Timer(const Duration(seconds: 4), _dismiss);
  }

  void _dismiss() {
    _animController.reverse().then((_) {
      if (mounted) {
        setState(() => _current = null);
        _showNext();
      }
    });
  }

  @override
  void dispose() {
    _animController.dispose();
    _dismissTimer?.cancel();
    _channel?.unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Keep user categories up to date for Galaxy filtering
    ref.listen(userBetCategoriesProvider, (_, next) {
      next.whenData((cats) => _userCategories = cats);
    });

    return Stack(
      children: [
        widget.child,
        if (_current != null)
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SlideTransition(
              position: _slideAnim,
              child: _FlashBannerBar(
                banner: _current!,
                onDismiss: _dismiss,
              ),
            ),
          ),
      ],
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Banner bar UI
// ─────────────────────────────────────────────────────────────────────────────

class _FlashBannerBar extends StatelessWidget {
  final PromotionBanner banner;
  final VoidCallback onDismiss;

  const _FlashBannerBar({required this.banner, required this.onDismiss});

  Color get _accentColor =>
      banner.isUniverse ? AppTheme.primary : AppTheme.secondary;

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top;

    return GestureDetector(
      onTap: onDismiss,
      child: Container(
        padding: EdgeInsets.fromLTRB(16, topPadding + 10, 16, 10),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              _accentColor.withValues(alpha: 0.92),
              _accentColor.withValues(alpha: 0.75),
            ],
            begin: Alignment.centerLeft,
            end: Alignment.centerRight,
          ),
          boxShadow: [
            BoxShadow(
              color: _accentColor.withValues(alpha: 0.4),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          children: [
            Text(
              banner.emoji,
              style: const TextStyle(fontSize: 18),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                banner.isUniverse
                    ? '${banner.emoji} @${banner.targetUsername} is on fire! (Universe)'
                    : '${banner.emoji} @${banner.targetUsername} — ${banner.category} (Galaxy)',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.2,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.close, color: Colors.white70, size: 16),
          ],
        ),
      ),
    );
  }
}
