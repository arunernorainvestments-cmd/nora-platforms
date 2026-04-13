import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../promotions/models/promotion_banner.dart';
import '../../promotions/providers/banner_providers.dart';
import '../providers/home_providers.dart';

// ─────────────────────────────────────────────────────────────────────────────
// HomeTicker — persistent scrolling strip at the top of the home screen.
// Shows: active Universe/Galaxy banners + Heat Score leaders.
// Subscribes to promotion_banners via Realtime so it updates live.
// ─────────────────────────────────────────────────────────────────────────────

class HomeTicker extends ConsumerStatefulWidget {
  const HomeTicker({super.key});

  @override
  ConsumerState<HomeTicker> createState() => _HomeTickerState();
}

class _HomeTickerState extends ConsumerState<HomeTicker>
    with SingleTickerProviderStateMixin {
  late final AnimationController _scrollController;
  late final Animation<double> _scrollAnimation;

  List<String> _items = [];
  RealtimeChannel? _channel;
  List<PromotionBanner> _activeBanners = [];
  Set<String> _userCategories = {};

  @override
  void initState() {
    super.initState();
    _scrollController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 20),
    )..addStatusListener((status) {
        if (status == AnimationStatus.completed) {
          _scrollController.repeat();
        }
      });
    _scrollAnimation = Tween<double>(begin: 0, end: 1).animate(_scrollController);
    _subscribeRealtime();
  }

  void _subscribeRealtime() {
    _channel = Supabase.instance.client
        .channel('home_ticker_banners')
        .onPostgresChanges(
          event: PostgresChangeEvent.insert,
          schema: 'public',
          table: 'promotion_banners',
          callback: (payload) {
            final row = payload.newRecord;
            if (row.isEmpty) return;
            try {
              final banner = PromotionBanner.fromJson(row);
              if (!banner.isCancelled && banner.isActive) {
                setState(() {
                  _activeBanners = [banner, ..._activeBanners];
                  _rebuildItems();
                });
              }
            } catch (_) {}
          },
        )
        .onPostgresChanges(
          event: PostgresChangeEvent.update,
          schema: 'public',
          table: 'promotion_banners',
          callback: (payload) {
            final row = payload.newRecord;
            if (row.isEmpty) return;
            final id = row['id'] as String?;
            if (id == null) return;
            setState(() {
              _activeBanners = _activeBanners
                  .where((b) => b.id != id || !(row['is_cancelled'] as bool? ?? false))
                  .toList();
              _rebuildItems();
            });
          },
        )
        .subscribe();
  }

  void _rebuildItems() {
    final bannerItems = _activeBanners.where((b) {
      if (!b.isActive) return false;
      if (b.isUniverse) return true;
      if (b.isGalaxy && b.category != null) {
        return _userCategories.contains(b.category);
      }
      return false;
    }).map((b) => b.tickerLabel).toList();

    if (bannerItems.isEmpty && _spotlightItems.isEmpty) {
      _items = ['🔥 N.O.R.A. Platforms — prediction markets on creator popularity'];
    } else {
      _items = [...bannerItems, ..._spotlightItems];
    }

    // Restart scroll at natural speed relative to item count
    final duration = Duration(seconds: 12 + _items.length * 6);
    _scrollController.duration = duration;
    if (!_scrollController.isAnimating) _scrollController.repeat();
  }

  List<String> _spotlightItems = [];

  void _setSpotlight(List<SpotlightCreator> creators) {
    _spotlightItems = creators
        .map((c) => '🔥 @${c.username ?? c.displayLabel} — ${c.score.toStringAsFixed(0)} Heat Score')
        .toList();
    _rebuildItems();
  }

  @override
  void dispose() {
    _scrollController.dispose();
    _channel?.unsubscribe();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watch providers and update items when data arrives
    ref.listen(activePromotionBannersProvider, (_, next) {
      next.whenData((banners) {
        _activeBanners = banners.where((b) => b.isActive).toList();
        _rebuildItems();
      });
    });
    ref.listen(userBetCategoriesProvider, (_, next) {
      next.whenData((cats) {
        _userCategories = cats;
        _rebuildItems();
      });
    });
    ref.listen(spotlightCreatorsProvider, (_, next) {
      next.whenData(_setSpotlight);
    });

    if (_items.isEmpty) {
      return const SizedBox(
        height: 32,
        child: Center(
          child: Text(
            '🔥 N.O.R.A. Platforms',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
        ),
      );
    }

    return Container(
      height: 32,
      color: AppTheme.surface,
      child: ClipRect(
        child: AnimatedBuilder(
          animation: _scrollAnimation,
          builder: (context, _) {
            return CustomPaint(
              painter: _TickerPainter(
                items: _items,
                progress: _scrollAnimation.value,
              ),
              child: const SizedBox.expand(),
            );
          },
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Ticker painter — renders items in a horizontal scrolling loop
// ─────────────────────────────────────────────────────────────────────────────

class _TickerPainter extends CustomPainter {
  final List<String> items;
  final double progress;

  static const _separator = '   ·   ';
  static const _fontSize = 12.0;

  _TickerPainter({required this.items, required this.progress});

  @override
  void paint(Canvas canvas, Size size) {
    final fullText = items.join(_separator) + _separator;

    final tp = TextPainter(
      text: TextSpan(
        text: fullText,
        style: const TextStyle(
          color: AppTheme.textSecondary,
          fontSize: _fontSize,
          fontWeight: FontWeight.w500,
          letterSpacing: 0.2,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout(maxWidth: double.infinity);

    final totalWidth = tp.width;
    final offset = -(progress * totalWidth);

    // Draw twice so it loops seamlessly
    canvas.save();
    canvas.clipRect(Rect.fromLTWH(0, 0, size.width, size.height));
    final dy = (size.height - tp.height) / 2;
    tp.paint(canvas, Offset(offset, dy));
    tp.paint(canvas, Offset(offset + totalWidth, dy));
    canvas.restore();
  }

  @override
  bool shouldRepaint(_TickerPainter old) =>
      old.progress != progress || old.items != items;
}
