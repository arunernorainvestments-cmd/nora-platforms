import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/providers/auth_provider.dart';

// ─────────────────────────────────────────────────────────────────────────────
// MODELS
// ─────────────────────────────────────────────────────────────────────────────

class PublicMarket {
  final String id;
  final String title;
  final String timeframe;
  final double yesPool;
  final double noPool;

  const PublicMarket({
    required this.id,
    required this.title,
    required this.timeframe,
    required this.yesPool,
    required this.noPool,
  });

  factory PublicMarket.fromJson(Map<String, dynamic> json) => PublicMarket(
        id: json['id'] as String,
        title: json['title'] as String,
        timeframe: json['timeframe'] as String,
        yesPool: (json['yes_pool'] as num?)?.toDouble() ?? 0,
        noPool: (json['no_pool'] as num?)?.toDouble() ?? 0,
      );

  double get totalPool => yesPool + noPool;
}

class PublicProfileData {
  final String id;
  final String username;
  final String? displayName;
  final String? bio;
  final bool isMarketMaker;
  final double? popularityScore;
  final bool popularityScorePublic;
  final String? avatarUrl;
  final String? spotlightTier;
  final List<String> connectedPlatforms;
  final List<PublicMarket> openMarkets;

  const PublicProfileData({
    required this.id,
    required this.username,
    this.displayName,
    this.bio,
    required this.isMarketMaker,
    this.popularityScore,
    required this.popularityScorePublic,
    this.avatarUrl,
    this.spotlightTier,
    required this.connectedPlatforms,
    required this.openMarkets,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// PROVIDER
// ─────────────────────────────────────────────────────────────────────────────

final publicProfileProvider =
    FutureProvider.autoDispose.family<PublicProfileData?, String>(
        (ref, username) async {
  final client = Supabase.instance.client;

  final profileData = await client
      .from('profiles')
      .select(
          'id, username, display_name, bio, is_market_maker, popularity_score, popularity_score_public, avatar_url')
      .eq('username', username)
      .maybeSingle();

  if (profileData == null) return null;

  final profileId = profileData['id'] as String;
  final isMarketMaker = profileData['is_market_maker'] as bool? ?? false;

  // Only fetch extended data for market makers
  String? spotlightTier;
  List<String> connectedPlatforms = [];
  List<PublicMarket> openMarkets = [];

  if (isMarketMaker) {
    // Spotlight tier
    final spotlightData = await client
        .from('spotlight_scores')
        .select('tier')
        .eq('user_id', profileId)
        .maybeSingle();
    spotlightTier = spotlightData?['tier'] as String?;

    // Social connections — readable only if viewer is the owner due to RLS.
    // The result will be empty for other viewers; the UI handles this gracefully.
    try {
      final connectionsData = await client
          .from('social_connections')
          .select('platform')
          .eq('user_id', profileId)
          .eq('is_active', true);
      connectedPlatforms = (connectionsData as List)
          .map((e) => e['platform'] as String)
          .toList();
    } catch (_) {}

    // Open markets for this creator
    final marketsData = await client
        .from('markets')
        .select('id, title, timeframe, yes_pool, no_pool')
        .eq('creator_id', profileId)
        .eq('status', 'open')
        .order('created_at', ascending: false);
    openMarkets = (marketsData as List)
        .map((e) => PublicMarket.fromJson(e as Map<String, dynamic>))
        .toList();
  }

  return PublicProfileData(
    id: profileId,
    username: profileData['username'] as String? ?? username,
    displayName: profileData['display_name'] as String?,
    bio: profileData['bio'] as String?,
    isMarketMaker: isMarketMaker,
    popularityScore: (profileData['popularity_score'] as num?)?.toDouble(),
    popularityScorePublic: profileData['popularity_score_public'] as bool? ?? false,
    avatarUrl: profileData['avatar_url'] as String?,
    spotlightTier: spotlightTier,
    connectedPlatforms: connectedPlatforms,
    openMarkets: openMarkets,
  );
});

// ─────────────────────────────────────────────────────────────────────────────
// SCREEN
// ─────────────────────────────────────────────────────────────────────────────

class PublicProfileScreen extends ConsumerWidget {
  final String username;
  const PublicProfileScreen({super.key, required this.username});

  void _copyShareLink(BuildContext context) {
    final url = 'https://nora-platforms.vercel.app/u/$username';
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Link copied to clipboard'),
        backgroundColor: AppTheme.surface,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: const BorderSide(color: AppTheme.cardBorder),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profileAsync = ref.watch(publicProfileProvider(username));
    final currentUser = ref.watch(currentUserProvider);

    return Scaffold(
      appBar: AppBar(
        title: Text('@$username'),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () =>
              context.canPop() ? context.pop() : context.go('/home'),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.share_outlined),
            tooltip: 'Copy profile link',
            onPressed: () => _copyShareLink(context),
          ),
        ],
      ),
      body: profileAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => _ErrorState(onRetry: () => ref.invalidate(publicProfileProvider(username))),
        data: (profile) {
          if (profile == null || !profile.isMarketMaker) {
            return _PrivateState(profile: profile);
          }
          return _PublicProfileBody(
            profile: profile,
            currentUser: currentUser,
            onMarketCreated: () => ref.invalidate(publicProfileProvider(username)),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PRIVATE / NOT FOUND STATE
// ─────────────────────────────────────────────────────────────────────────────

class _PrivateState extends StatelessWidget {
  final PublicProfileData? profile;
  const _PrivateState({this.profile});

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_outline,
                size: 56, color: AppTheme.textSecondary),
            const SizedBox(height: 20),
            const Text(
              'This profile is private',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'This user has not enabled a public Market Maker profile.',
              textAlign: TextAlign.center,
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 32),
            ElevatedButton(
              onPressed: () => context.go('/login'),
              child: const Text('Sign In to Continue'),
            ),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PUBLIC PROFILE BODY
// ─────────────────────────────────────────────────────────────────────────────

class _PublicProfileBody extends StatelessWidget {
  final PublicProfileData profile;
  final User? currentUser;
  final VoidCallback onMarketCreated;

  const _PublicProfileBody({
    required this.profile,
    required this.currentUser,
    required this.onMarketCreated,
  });

  void _onOpenMarket(BuildContext context) {
    if (currentUser == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Sign in to open a market'),
          action: SnackBarAction(
            label: 'Sign In',
            textColor: AppTheme.primary,
            onPressed: () => context.go('/login'),
          ),
          backgroundColor: AppTheme.surface,
          behavior: SnackBarBehavior.floating,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
            side: const BorderSide(color: AppTheme.cardBorder),
          ),
        ),
      );
      return;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _OpenMarketSheet(
        creatorId: profile.id,
        creatorUsername: profile.username,
        currentUserId: currentUser!.id,
        onCreated: onMarketCreated,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final avatarLetter = profile.username.isNotEmpty
        ? profile.username[0].toUpperCase()
        : '?';

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header ─────────────────────────────────────────────────────────
          Center(
            child: Column(
              children: [
                CircleAvatar(
                  radius: 44,
                  backgroundColor: AppTheme.primary,
                  child: Text(
                    avatarLetter,
                    style: const TextStyle(
                      fontSize: 32,
                      color: Colors.white,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                Text(
                  '@${profile.username}',
                  style: const TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary,
                  ),
                ),
                if (profile.displayName != null &&
                    profile.displayName!.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    profile.displayName!,
                    style: const TextStyle(
                      fontSize: 15,
                      color: AppTheme.textSecondary,
                    ),
                  ),
                ],
                const SizedBox(height: 10),
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (profile.spotlightTier != null)
                      _TierBadge(tier: profile.spotlightTier!),
                    if (profile.spotlightTier != null &&
                        profile.popularityScorePublic &&
                        profile.popularityScore != null)
                      const SizedBox(width: 8),
                    if (profile.popularityScorePublic &&
                        profile.popularityScore != null)
                      _ScoreBadge(score: profile.popularityScore!),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),

          // ── Bio ─────────────────────────────────────────────────────────────
          if (profile.bio != null && profile.bio!.isNotEmpty) ...[
            Text(
              profile.bio!,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 24),
          ],

          // ── Connected Platforms ─────────────────────────────────────────────
          if (profile.connectedPlatforms.isNotEmpty) ...[
            const _SectionTitle('Connected Platforms'),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: profile.connectedPlatforms
                  .map((p) => _PlatformChip(platform: p))
                  .toList(),
            ),
            const SizedBox(height: 24),
          ],

          // ── Open Markets ────────────────────────────────────────────────────
          const _SectionTitle('Open Markets'),
          const SizedBox(height: 10),
          if (profile.openMarkets.isEmpty)
            Container(
              padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 16),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: AppTheme.cardBorder),
              ),
              child: const Center(
                child: Text(
                  'No open markets yet',
                  style: TextStyle(color: AppTheme.textSecondary),
                ),
              ),
            )
          else
            ...profile.openMarkets.map((m) => _MarketCard(market: m)),
          const SizedBox(height: 20),

          // ── Open a Market button ─────────────────────────────────────────────
          ElevatedButton.icon(
            onPressed: () => _onOpenMarket(context),
            icon: const Icon(Icons.add_chart_outlined, size: 18),
            label: const Text('Open a Market'),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// OPEN MARKET BOTTOM SHEET
// ─────────────────────────────────────────────────────────────────────────────

class _OpenMarketSheet extends StatefulWidget {
  final String creatorId;
  final String creatorUsername;
  final String currentUserId;
  final VoidCallback onCreated;

  const _OpenMarketSheet({
    required this.creatorId,
    required this.creatorUsername,
    required this.currentUserId,
    required this.onCreated,
  });

  @override
  State<_OpenMarketSheet> createState() => _OpenMarketSheetState();
}

class _OpenMarketSheetState extends State<_OpenMarketSheet> {
  final _titleController = TextEditingController();
  final _changePctController = TextEditingController(text: '5');
  String _timeframe = '7d';
  bool _isSubmitting = false;
  String? _error;

  static const _timeframes = ['24h', '7d', '30d'];

  @override
  void dispose() {
    _titleController.dispose();
    _changePctController.dispose();
    super.dispose();
  }

  DateTime _endAt(String timeframe) {
    final now = DateTime.now().toUtc();
    return switch (timeframe) {
      '24h' => now.add(const Duration(hours: 24)),
      '7d' => now.add(const Duration(days: 7)),
      _ => now.add(const Duration(days: 30)),
    };
  }

  Future<void> _submit() async {
    final title = _titleController.text.trim();
    if (title.isEmpty) {
      setState(() => _error = 'Title is required');
      return;
    }
    final changePct = double.tryParse(_changePctController.text.trim());
    if (changePct == null || changePct <= 0) {
      setState(() => _error = 'Enter a valid target % change');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _error = null;
    });

    try {
      await Supabase.instance.client.from('markets').insert({
        'creator_id': widget.creatorId,
        'created_by': widget.currentUserId,
        'opened_by': widget.currentUserId,
        'title': title,
        'timeframe': _timeframe,
        'target_change_pct': changePct,
        'end_at': _endAt(_timeframe).toIso8601String(),
        'status': 'open',
      });
      if (mounted) {
        Navigator.of(context).pop();
        widget.onCreated();
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final keyboardHeight = MediaQuery.of(context).viewInsets.bottom;

    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.fromLTRB(24, 20, 24, 24 + keyboardHeight),
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
          Text(
            'Open a Market on @${widget.creatorUsername}',
            style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _titleController,
            decoration: const InputDecoration(
              labelText: 'Market title',
              hintText: 'e.g. Will they hit 1M followers?',
            ),
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _changePctController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(
                    labelText: 'Target change %',
                    suffixText: '%',
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: InputDecorator(
                  decoration: InputDecoration(
                    labelText: 'Timeframe',
                    labelStyle: const TextStyle(color: AppTheme.textSecondary),
                    enabledBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppTheme.cardBorder),
                    ),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(12),
                      borderSide: const BorderSide(color: AppTheme.cardBorder),
                    ),
                    filled: true,
                    fillColor: AppTheme.surfaceLight,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12, vertical: 4),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _timeframe,
                      dropdownColor: AppTheme.surface,
                      isExpanded: true,
                      style: const TextStyle(color: AppTheme.textPrimary),
                      items: _timeframes
                          .map((t) => DropdownMenuItem(
                                value: t,
                                child: Text(t),
                              ))
                          .toList(),
                      onChanged: (v) {
                        if (v != null) setState(() => _timeframe = v);
                      },
                    ),
                  ),
                ),
              ),
            ],
          ),
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                style: const TextStyle(color: AppTheme.danger, fontSize: 13)),
          ],
          const SizedBox(height: 20),
          ElevatedButton(
            onPressed: _isSubmitting ? null : _submit,
            child: _isSubmitting
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(
                        strokeWidth: 2, color: Colors.white))
                : const Text('Create Market'),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// SHARED WIDGETS
// ─────────────────────────────────────────────────────────────────────────────

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle(this.title);

  @override
  Widget build(BuildContext context) => Text(
        title,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: AppTheme.textSecondary,
          letterSpacing: 0.5,
        ),
      );
}

class _TierBadge extends StatelessWidget {
  final String tier;
  const _TierBadge({required this.tier});

  static const _labels = {
    'on_fire': ('🔥', 'On Fire', Color(0xFFFF6B35)),
    'rising': ('⚡', 'Rising', Color(0xFFFFD700)),
    'watched': ('👀', 'Watched', AppTheme.primary),
    'listed': ('', 'Listed', AppTheme.textSecondary),
  };

  @override
  Widget build(BuildContext context) {
    final info = _labels[tier] ?? _labels['listed']!;
    final color = info.$3;
    final label = '${info.$1} ${info.$2}'.trim();
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _ScoreBadge extends StatelessWidget {
  final double score;
  const _ScoreBadge({required this.score});

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: AppTheme.secondary.withValues(alpha: 0.15),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.secondary.withValues(alpha: 0.5)),
        ),
        child: Text(
          'Score ${score.toStringAsFixed(1)}',
          style: const TextStyle(
            color: AppTheme.secondary,
            fontSize: 12,
            fontWeight: FontWeight.bold,
          ),
        ),
      );
}

class _PlatformChip extends StatelessWidget {
  final String platform;
  const _PlatformChip({required this.platform});

  static const _colors = {
    'youtube': Color(0xFFFF4444),
    'tiktok': Color(0xFFEE1D52),
    'x': Color(0xFF8B8FA8),
    'instagram': Color(0xFFE1306C),
    'kick': Color(0xFF53FC18),
    'pinterest': Color(0xFFE60023),
  };

  static const _labels = {
    'youtube': 'YouTube',
    'tiktok': 'TikTok',
    'x': 'X',
    'instagram': 'Instagram',
    'kick': 'Kick',
    'pinterest': 'Pinterest',
  };

  @override
  Widget build(BuildContext context) {
    final color = _colors[platform] ?? AppTheme.textSecondary;
    final label = _labels[platform] ?? platform;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _MarketCard extends StatelessWidget {
  final PublicMarket market;
  const _MarketCard({required this.market});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  market.title,
                  style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  '${market.timeframe} · ${market.totalPool.toStringAsFixed(0)} tokens pooled',
                  style: const TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: AppTheme.success.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: AppTheme.success.withValues(alpha: 0.4)),
            ),
            child: const Text(
              'OPEN',
              style: TextStyle(
                color: AppTheme.success,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final VoidCallback onRetry;
  const _ErrorState({required this.onRetry});

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.wifi_off_rounded,
                size: 48, color: AppTheme.textSecondary),
            const SizedBox(height: 16),
            const Text('Could not load profile',
                style: TextStyle(color: AppTheme.textSecondary)),
            const SizedBox(height: 16),
            TextButton(
              onPressed: onRetry,
              child: const Text('Retry',
                  style: TextStyle(color: AppTheme.primary)),
            ),
          ],
        ),
      );
}
