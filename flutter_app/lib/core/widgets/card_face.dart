import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// The BattleChit display face — the app-rendered card template (chip frame + all
/// text/stats) composited over the clean, text-free AI illustration. This is the
/// "systemic uniformity" layer: the frame, the violet→teal piping and the layout are
/// identical on every card; only the family-accent hue and the schema content vary.
/// Text is rendered here (never baked into the art) so stats can change and there is
/// no AI text garble — the same principle Unity will use in-game.
///
/// Designed on a fixed 2:3 canvas and scaled with a FittedBox, so one widget serves
/// both the large mint-preview hero and smaller collection cards.
class CardFace extends StatelessWidget {
  const CardFace({
    super.key,
    required this.name,
    required this.chitType,
    required this.family,
    required this.tier,
    required this.auraCost,
    this.atk,
    this.hp,
    this.keywords = const [],
    this.cardArtUrl,
    this.minterHandle,
    this.sourcePlatform,
    this.rulesText,
    this.flavor,
    this.serial,
    this.copyOf,
  });

  final String name;
  final String chitType; // 'creature' | 'spell_moment'
  final String family;
  final String tier;
  final int auraCost;
  final int? atk;
  final int? hp;
  final List<String> keywords;
  final String? cardArtUrl;
  final String? minterHandle;
  final String? sourcePlatform;
  final String? rulesText;
  final String? flavor;
  final String? serial;

  /// Per-copy serialization line, e.g. '#3 of 100' (Collections spec N2 —
  /// chit_copies.serial_number / total_supply). Distinct from [serial], the
  /// definition-level catalog serial ('NORA-0042').
  final String? copyOf;

  bool get _isCreature => chitType != 'spell_moment';

  /// Family → accent hue. Mirrors FAMILY_ACCENT in
  /// supabase/functions/_shared/cinematic_directives.ts so the AI illustration glow
  /// and this app-rendered chrome read as the same colour.
  static const Map<String, Color> familyAccent = {
    'athlete': Color(0xFFFF5A1F),
    'musician': Color(0xFFFF3DBE),
    'artist': Color(0xFFB15CFF),
    'scientist': Color(0xFF2BE0C8),
    'comedian': Color(0xFFB6E62E),
    'influencer': Color(0xFFFF4D9D),
    'politician': Color(0xFFFF3B3B),
    'business': Color(0xFFFFC53D),
    'gamer': Color(0xFF39FF14),
    'actor': Color(0xFFE8D9A0),
  };

  Color get _accent => familyAccent[family.toLowerCase()] ?? AppTheme.primary;

  static const _body = Color(0xFF1A1A2E);
  static const _bodyDark = Color(0xFF12121F);

  @override
  Widget build(BuildContext context) {
    // Fixed design canvas; FittedBox scales the whole card to the given box.
    return AspectRatio(
      aspectRatio: 2 / 3,
      child: FittedBox(
        fit: BoxFit.contain,
        child: SizedBox(width: 680, height: 1020, child: _card()),
      ),
    );
  }

  Widget _card() {
    return Container(
      // The fixed brand piping: violet→teal gradient tracing the border.
      padding: const EdgeInsets.all(5),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(34),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [AppTheme.primary, AppTheme.secondary],
        ),
        boxShadow: [
          BoxShadow(color: _accent.withValues(alpha: 0.35), blurRadius: 40, spreadRadius: 2),
        ],
      ),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(30),
          gradient: const LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [_body, _bodyDark],
          ),
          border: Border.all(color: const Color(0xFF3A3A55), width: 2),
        ),
        child: Stack(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(40, 22, 26, 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _titleBar(),
                  const SizedBox(height: 12),
                  _subtitleStrip(),
                  const SizedBox(height: 14),
                  Expanded(flex: 5, child: _artWindow()),
                  const SizedBox(height: 14),
                  _typeLine(),
                  const SizedBox(height: 10),
                  Expanded(flex: 3, child: _rulesBox()),
                  const SizedBox(height: 12),
                  _creditStrip(),
                ],
              ),
            ),
            // Left-edge connector pins (the NT-Warrior chip contact ridges).
            const Positioned(left: 12, top: 150, bottom: 150, child: _PinStrip()),
            // Persistent-body stat nub — creatures only.
            if (_isCreature)
              Positioned(right: 20, bottom: 92, child: _statNub()),
          ],
        ),
      ),
    );
  }

  Widget _titleBar() {
    return _bar(
      child: Row(
        children: [
          Expanded(
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 34,
                fontWeight: FontWeight.w800,
                letterSpacing: 0.3,
              ),
            ),
          ),
          const SizedBox(width: 8),
          _hex(
            size: 52,
            fill: AppTheme.primary,
            child: Text('$auraCost',
                style: const TextStyle(
                    color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
          ),
        ],
      ),
    );
  }

  Widget _subtitleStrip() {
    return _bar(
      dense: true,
      child: Row(
        children: [
          _hex(
            size: 40,
            fill: _accent,
            child: Text(tier.toUpperCase(),
                style: TextStyle(
                    color: _readableOn(_accent),
                    fontSize: 20,
                    fontWeight: FontWeight.w900)),
          ),
          const SizedBox(width: 12),
          Text(_titleCase(family),
              style: const TextStyle(
                  color: Colors.white, fontSize: 22, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }

  Widget _artWindow() {
    return Container(
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: _accent.withValues(alpha: 0.85), width: 3),
        boxShadow: [BoxShadow(color: _accent.withValues(alpha: 0.30), blurRadius: 18)],
      ),
      clipBehavior: Clip.antiAlias,
      child: cardArtUrl != null
          ? Image.network(cardArtUrl!,
              fit: BoxFit.cover,
              errorBuilder: (_, __, ___) => _artFallback())
          : _artFallback(),
    );
  }

  Widget _artFallback() => Container(
        color: _bodyDark,
        child: Center(child: Icon(Icons.auto_awesome, color: _accent, size: 56)),
      );

  Widget _typeLine() {
    final label = '${_isCreature ? 'Creature' : 'Spell-Moment'} — ${_titleCase(family)}';
    return _bar(
      dense: true,
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: Colors.white, fontSize: 22, fontWeight: FontWeight.w700)),
          ),
          for (final kw in keywords.take(2)) ...[
            const SizedBox(width: 6),
            _keywordIcon(kw),
          ],
        ],
      ),
    );
  }

  Widget _rulesBox() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 14),
      decoration: BoxDecoration(
        color: _bodyDark.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF3A3A55)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (rulesText != null && rulesText!.trim().isNotEmpty)
            Text(rulesText!,
                style: const TextStyle(
                    color: Colors.white, fontSize: 21, height: 1.25)),
          if (flavor != null && flavor!.trim().isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(flavor!,
                style: const TextStyle(
                    color: Color(0xFFB8B8CC),
                    fontSize: 19,
                    height: 1.2,
                    fontStyle: FontStyle.italic)),
          ],
        ],
      ),
    );
  }

  Widget _creditStrip() {
    final left = minterHandle == null
        ? ''
        : 'Minted from ${minterHandle!}${sourcePlatform != null ? ' · ${_titleCase(sourcePlatform!)}' : ''}';
    final right = [
      if (serial != null) serial!,
      if (copyOf != null) copyOf!,
      if (tier.isNotEmpty) '${tier.toUpperCase()}-Tier',
    ].join(' · ');
    return Row(
      children: [
        Expanded(
          child: Text(left,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Color(0xFF9A9AB4), fontSize: 16)),
        ),
        if (right.isNotEmpty)
          Text(right,
              style: const TextStyle(color: Color(0xFF9A9AB4), fontSize: 16)),
      ],
    );
  }

  Widget _statNub() {
    return _hex(
      size: 88,
      fill: const Color(0xFF2A2A44),
      border: _accent,
      child: Text('${atk ?? 0}/${hp ?? 0}',
          style: const TextStyle(
              color: Colors.white, fontSize: 26, fontWeight: FontWeight.w800)),
    );
  }

  Widget _keywordIcon(String kw) {
    final k = kw.toLowerCase();
    final icon = k.contains('taunt')
        ? Icons.shield
        : k.contains('charge')
            ? Icons.bolt
            : k.contains('heal')
                ? Icons.favorite
                : Icons.auto_awesome;
    return Tooltip(
      message: _titleCase(kw),
      child: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: _bodyDark,
          shape: BoxShape.circle,
          border: Border.all(color: _accent, width: 2),
        ),
        child: Icon(icon, size: 22, color: _accent),
      ),
    );
  }

  // ── shared frame primitives ───────────────────────────────────────────────
  Widget _bar({required Widget child, bool dense = false}) => Container(
        padding: EdgeInsets.symmetric(horizontal: 16, vertical: dense ? 8 : 12),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          gradient: const LinearGradient(
            colors: [Color(0xFF26263E), Color(0xFF1C1C30)],
          ),
          border: Border.all(color: const Color(0xFF3A3A55)),
        ),
        child: child,
      );

  Widget _hex({
    required double size,
    required Color fill,
    required Widget child,
    Color? border,
  }) =>
      ClipPath(
        clipper: _HexClipper(),
        child: Container(
          width: size,
          height: size,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: fill,
            border: border != null ? Border.all(color: border, width: 2) : null,
          ),
          child: child,
        ),
      );

  static Color _readableOn(Color bg) =>
      bg.computeLuminance() > 0.55 ? const Color(0xFF1A1A2E) : Colors.white;

  static String _titleCase(String s) => s.isEmpty
      ? s
      : s
          .split(RegExp(r'[_\s]+'))
          .map((w) => w.isEmpty ? w : '${w[0].toUpperCase()}${w.substring(1)}')
          .join(' ');
}

/// A flat-top hexagon, matching the badge/gem/stat-nub shapes in the references.
class _HexClipper extends CustomClipper<Path> {
  @override
  Path getClip(Size size) {
    final w = size.width, h = size.height;
    return Path()
      ..moveTo(w * 0.25, 0)
      ..lineTo(w * 0.75, 0)
      ..lineTo(w, h * 0.5)
      ..lineTo(w * 0.75, h)
      ..lineTo(w * 0.25, h)
      ..lineTo(0, h * 0.5)
      ..close();
  }

  @override
  bool shouldReclip(covariant CustomClipper<Path> oldClipper) => false;
}

/// The vertical row of ridged connector pins down the card's left edge.
class _PinStrip extends StatelessWidget {
  const _PinStrip();

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
      children: List.generate(
        11,
        (_) => Container(
          width: 16,
          height: 10,
          margin: const EdgeInsets.symmetric(vertical: 3),
          decoration: BoxDecoration(
            color: const Color(0xFF3A3A55),
            borderRadius: BorderRadius.circular(3),
            boxShadow: const [
              BoxShadow(color: Color(0xFF0A0A12), offset: Offset(0, 1), blurRadius: 1),
            ],
          ),
        ),
      ),
    );
  }
}
