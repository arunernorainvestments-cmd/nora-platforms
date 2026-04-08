import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/utils/open_url.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/providers/auth_provider.dart';
import '../providers/platform_connection_providers.dart';
import '../providers/profile_providers.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _displayNameController = TextEditingController();
  final _bioController = TextEditingController();
  bool _editInitialized = false;
  bool _isSaving = false;
  bool _isTogglingMarketMaker = false;

  @override
  void dispose() {
    _displayNameController.dispose();
    _bioController.dispose();
    super.dispose();
  }

  void _maybeInitControllers(UserProfile profile) {
    if (_editInitialized) return;
    _displayNameController.text = profile.displayName ?? '';
    _bioController.text = profile.bio ?? '';
    _editInitialized = true;
  }

  void _openMarketMakerSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _MarketMakerOptInSheet(
        onComplete: () {
          ref.invalidate(userProfileProvider);
          ref.invalidate(spotlightTierProvider);
        },
      ),
    );
  }

  Future<void> _toggleMarketMaker(
      BuildContext context, UserProfile profile) async {
    setState(() => _isTogglingMarketMaker = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      final actions = ref.read(profileActionsProvider);
      if (profile.isMarketMaker && !profile.pendingOptOut) {
        await actions.optOutMarketMaker();
        ref.invalidate(userProfileProvider);
        if (mounted) {
          // Refresh to check if pending_opt_out was set
          final updated = await ref.read(userProfileProvider.future);
          if (mounted && updated != null && updated.pendingOptOut) {
            messenger.showSnackBar(
              const SnackBar(
                content: Text(
                    'You will be opted out after your current markets close'),
              ),
            );
          }
        }
      } else if (profile.pendingOptOut) {
        await actions.resumeMarketMaker();
        ref.invalidate(userProfileProvider);
      }
    } catch (e) {
      if (mounted) {
        messenger.showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isTogglingMarketMaker = false);
    }
  }

  Future<void> _saveProfile() async {
    setState(() { _isSaving = true; });
    try {
      await ref.read(profileActionsProvider).updateProfile(
        displayName: _displayNameController.text.trim(),
        bio: _bioController.text.trim(),
      );
      ref.invalidate(userProfileProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Profile saved')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() { _isSaving = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    final profileAsync = ref.watch(userProfileProvider);
    final balanceAsync = ref.watch(profileTokenBalanceProvider);
    final tierAsync = ref.watch(spotlightTierProvider);
    final user = ref.watch(currentUserProvider);

    profileAsync.whenData((p) { if (p != null) _maybeInitControllers(p); });

    return Scaffold(
      appBar: AppBar(
        title: const Text('Profile'),
        actions: [
          balanceAsync.when(
            data: (balance) => Padding(
              padding: const EdgeInsets.only(right: 16),
              child: Center(
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: AppTheme.primary.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: AppTheme.primary.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.toll_outlined,
                          size: 15, color: AppTheme.primary),
                      const SizedBox(width: 4),
                      Text(
                        '$balance',
                        style: const TextStyle(
                            color: AppTheme.primary,
                            fontWeight: FontWeight.bold,
                            fontSize: 13),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            loading: () => const SizedBox.shrink(),
            error: (_, __) => const SizedBox.shrink(),
          ),
        ],
      ),
      body: profileAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => Center(
          child: Text('Failed to load profile: $e',
              style: const TextStyle(color: AppTheme.danger)),
        ),
        data: (profile) {
          if (profile == null) {
            return const Center(
              child: Text('Profile not found.',
                  style: TextStyle(color: AppTheme.textSecondary)),
            );
          }

          final displayUsername =
              profile.username ?? user?.email?.split('@').first ?? 'user';
          final avatarLetter = displayUsername[0].toUpperCase();
          final email = user?.email ?? '';

          return SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── Header ────────────────────────────────────────────────
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
                              fontWeight: FontWeight.bold),
                        ),
                      ),
                      const SizedBox(height: 12),
                      Text(
                        displayUsername,
                        style: const TextStyle(
                            fontSize: 22,
                            fontWeight: FontWeight.bold,
                            color: AppTheme.textPrimary),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        email,
                        style: const TextStyle(
                            fontSize: 13,
                            color: AppTheme.textSecondary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 28),

                // ── Market Maker section ──────────────────────────────────
                if (!profile.isMarketMaker)
                  _MarketMakerOptInCard(
                    onGetStarted: () => _openMarketMakerSheet(context),
                  )
                else
                  _MarketMakerDashboard(
                    tierAsync: tierAsync,
                    username: displayUsername,
                    pendingOptOut: profile.pendingOptOut,
                    isToggling: _isTogglingMarketMaker,
                    onToggle: () => _toggleMarketMaker(context, profile),
                  ),
                const SizedBox(height: 24),

                // ── Invite friends ────────────────────────────────────────
                if (profile.referralCode != null)
                  _InviteFriendsCard(referralCode: profile.referralCode!),
                const SizedBox(height: 24),

                // ── Edit profile ──────────────────────────────────────────
                const _SectionTitle('Edit Profile'),
                const SizedBox(height: 12),
                TextField(
                  controller: _displayNameController,
                  decoration: const InputDecoration(
                    labelText: 'Display Name',
                    prefixIcon: Icon(Icons.person_outline,
                        color: AppTheme.textSecondary),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _bioController,
                  maxLines: 3,
                  decoration: const InputDecoration(
                    labelText: 'Bio',
                    prefixIcon: Icon(Icons.edit_note,
                        color: AppTheme.textSecondary),
                    alignLabelWithHint: true,
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton(
                  onPressed: _isSaving ? null : _saveProfile,
                  child: _isSaving
                      ? const SizedBox(
                          height: 20,
                          width: 20,
                          child: CircularProgressIndicator(
                              strokeWidth: 2, color: Colors.white))
                      : const Text('Save'),
                ),
                const SizedBox(height: 32),

                // ── Sign out ──────────────────────────────────────────────
                ElevatedButton.icon(
                  onPressed: () =>
                      ref.read(authActionsProvider).signOut(),
                  icon: const Icon(Icons.logout),
                  label: const Text('Sign Out'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: AppTheme.danger,
                    minimumSize: const Size(double.infinity, 50),
                  ),
                ),
                const SizedBox(height: 24),
              ],
            ),
          );
        },
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARKET MAKER OPT-IN CARD (when not yet a market maker)
// ─────────────────────────────────────────────────────────────────────────────

class _MarketMakerOptInCard extends StatelessWidget {
  final VoidCallback onGetStarted;
  const _MarketMakerOptInCard({required this.onGetStarted});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.show_chart,
                    color: AppTheme.primary, size: 22),
              ),
              const SizedBox(width: 12),
              const Text(
                'Become a Market Maker',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Let the community bet on your popularity. Get discovered by new followers.',
            style: TextStyle(color: AppTheme.textSecondary, height: 1.5),
          ),
          const SizedBox(height: 16),

          // Step indicators
          const _StepIndicator(
            steps: [
              '1. Connect a social account',
              '2. Accept terms',
              '3. Go live',
            ],
          ),
          const SizedBox(height: 16),

          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: onGetStarted,
              child: const Text('Get Started'),
            ),
          ),
        ],
      ),
    );
  }
}

class _StepIndicator extends StatelessWidget {
  final List<String> steps;
  const _StepIndicator({required this.steps});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: steps.map((s) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          children: [
            const Icon(Icons.circle, size: 6, color: AppTheme.primary),
            const SizedBox(width: 8),
            Text(s, style: const TextStyle(
                color: AppTheme.textSecondary, fontSize: 13)),
          ],
        ),
      )).toList(),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARKET MAKER DASHBOARD (when already a market maker)
// ─────────────────────────────────────────────────────────────────────────────

class _MarketMakerDashboard extends StatelessWidget {
  final AsyncValue<String?> tierAsync;
  final String username;
  final bool pendingOptOut;
  final bool isToggling;
  final VoidCallback onToggle;

  const _MarketMakerDashboard({
    required this.tierAsync,
    required this.username,
    required this.pendingOptOut,
    required this.isToggling,
    required this.onToggle,
  });

  void _copyProfileLink(BuildContext context) {
    const base = 'https://nora-platforms.vercel.app/u/';
    Clipboard.setData(ClipboardData(text: '$base$username'));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Profile link copied to clipboard'),
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
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.secondary.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Title row + tier badge
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Market Maker',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary),
              ),
              tierAsync.when(
                data: (tier) => tier != null
                    ? _TierBadge(tier)
                    : const SizedBox.shrink(),
                loading: () => const SizedBox.shrink(),
                error: (_, __) => const SizedBox.shrink(),
              ),
            ],
          ),
          const SizedBox(height: 14),

          // Public profile link
          GestureDetector(
            onTap: () => _copyProfileLink(context),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              decoration: BoxDecoration(
                color: AppTheme.background,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppTheme.cardBorder),
              ),
              child: Row(
                children: [
                  const Icon(Icons.link, size: 15, color: AppTheme.primary),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      'nora-platforms.vercel.app/u/$username',
                      style: const TextStyle(
                        color: AppTheme.primary,
                        fontSize: 12,
                        fontFamily: 'monospace',
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  const Icon(Icons.copy_outlined,
                      size: 14, color: AppTheme.textSecondary),
                ],
              ),
            ),
          ),
          const SizedBox(height: 14),

          // Accept new markets toggle
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: AppTheme.surfaceLight,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.cardBorder),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'Accept new markets',
                            style: TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Allow users to open prediction markets on you',
                            style: TextStyle(
                                color: AppTheme.textSecondary, fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                    isToggling
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: AppTheme.primary),
                          )
                        : Switch(
                            value: !pendingOptOut,
                            onChanged: (_) => onToggle(),
                            activeThumbColor: AppTheme.primary,
                            activeTrackColor:
                                AppTheme.primary.withValues(alpha: 0.4),
                          ),
                  ],
                ),
                if (pendingOptOut) ...[
                  const SizedBox(height: 6),
                  const Text(
                    'You will be opted out after your current markets close',
                    style: TextStyle(
                        color: AppTheme.danger,
                        fontSize: 12),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 18),

          // Social connect buttons
          const Text(
            'Connect Social Accounts',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 12),
          const Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _PlatformConnectionTile(platform: 'youtube'),
              _PlatformConnectionTile(platform: 'twitch'),
              _PlatformConnectionTile(platform: 'tiktok', isStub: true),
              _PlatformConnectionTile(platform: 'x', isStub: true),
              _PlatformConnectionTile(platform: 'instagram', isStub: true),
              _PlatformConnectionTile(platform: 'kick', isStub: true),
            ],
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// MARKET MAKER OPT-IN BOTTOM SHEET (3 steps)
// ─────────────────────────────────────────────────────────────────────────────

class _MarketMakerOptInSheet extends ConsumerStatefulWidget {
  final VoidCallback onComplete;
  const _MarketMakerOptInSheet({required this.onComplete});

  @override
  ConsumerState<_MarketMakerOptInSheet> createState() =>
      _MarketMakerOptInSheetState();
}

class _MarketMakerOptInSheetState
    extends ConsumerState<_MarketMakerOptInSheet> {
  int _step = 0;
  final Set<String> _attemptedPlatforms = {};
  bool _agreed = false;
  bool _isSubmitting = false;
  String? _error;

  static const _platforms = [
    ('youtube', 'YouTube', Icons.play_circle_outline),
    ('twitch', 'Twitch', Icons.sports_esports_outlined),
    ('tiktok', 'TikTok', Icons.music_note_outlined),
    ('x', 'X', Icons.alternate_email),
    ('instagram', 'Instagram', Icons.photo_camera_outlined),
    ('kick', 'Kick', Icons.sports_esports_outlined),
  ];

  Future<void> _tapPlatform(BuildContext context, String platform) async {
    setState(() => _attemptedPlatforms.add(platform));

    if (platform == 'youtube' || platform == 'twitch') {
      final messenger = ScaffoldMessenger.of(context);
      try {
        final user = Supabase.instance.client.auth.currentUser;
        if (user == null) throw Exception('Not authenticated');
        final res = await Supabase.instance.client.functions.invoke(
          'oauth-initiate',
          body: {'platform': platform, 'user_id': user.id},
        );
        final authUrl = res.data['auth_url'] as String?;
        if (authUrl != null) {
          await openUrlInBrowser(authUrl);
        }
      } catch (_) {
        if (mounted) {
          messenger.showSnackBar(
            const SnackBar(
              content: Text('Failed to start connection. Try again.'),
              duration: Duration(seconds: 2),
              behavior: SnackBarBehavior.floating,
            ),
          );
        }
      }
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Coming in a future update'),
        duration: Duration(seconds: 2),
        behavior: SnackBarBehavior.floating,
      ),
    );
  }

  Future<void> _goLive() async {
    setState(() { _isSubmitting = true; _error = null; });
    try {
      await ref.read(profileActionsProvider).becomeMarketMaker();
      if (mounted) {
        Navigator.of(context).pop();
        widget.onComplete();
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Something went wrong. Please try again.';
          _isSubmitting = false;
        });
      }
    }
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

          // Step indicator pills
          Row(
            children: List.generate(3, (i) {
              final isActive = i == _step;
              final isDone = i < _step;
              return Expanded(
                child: Container(
                  margin: EdgeInsets.only(right: i < 2 ? 6 : 0),
                  height: 4,
                  decoration: BoxDecoration(
                    color: isDone || isActive
                        ? AppTheme.primary
                        : AppTheme.cardBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              );
            }),
          ),
          const SizedBox(height: 24),

          if (_step == 0) _buildStep1(context),
          if (_step == 1) _buildStep2(context),
          if (_step == 2) _buildStep3(context),
        ],
      ),
    );
  }

  Widget _buildStep1(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          'Connect a Social Account',
          style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary),
        ),
        const SizedBox(height: 8),
        const Text(
          'Tap at least one platform to continue. Social connections are coming in Phase 3 — tap to register your interest.',
          style: TextStyle(
              color: AppTheme.textSecondary, height: 1.5, fontSize: 13),
        ),
        const SizedBox(height: 20),
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: _platforms.map((p) {
            final connected = _attemptedPlatforms.contains(p.$1);
            return OutlinedButton.icon(
              onPressed: () => _tapPlatform(context, p.$1).ignore(),
              icon: Icon(p.$3, size: 16,
                  color: connected ? AppTheme.primary : AppTheme.textSecondary),
              label: Text(
                connected ? '${p.$2} ✓' : p.$2,
                style: TextStyle(
                  fontSize: 13,
                  color: connected ? AppTheme.primary : AppTheme.textSecondary,
                ),
              ),
              style: OutlinedButton.styleFrom(
                side: BorderSide(
                  color: connected ? AppTheme.primary : AppTheme.cardBorder,
                ),
                padding: const EdgeInsets.symmetric(
                    horizontal: 12, vertical: 10),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 20),
        ElevatedButton(
          onPressed: _attemptedPlatforms.isNotEmpty
              ? () => setState(() => _step = 1)
              : null,
          child: const Text('Next'),
        ),
      ],
    );
  }

  Widget _buildStep2(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            IconButton(
              onPressed: () => setState(() => _step = 0),
              icon: const Icon(Icons.arrow_back,
                  color: AppTheme.textSecondary, size: 20),
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 8),
            const Text(
              'Accept Terms',
              style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.surfaceLight,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.cardBorder),
          ),
          child: const Text(
            'By becoming a Market Maker you agree that other users can open prediction markets on your popularity score. Your score is calculated from your linked social accounts. You can opt out at any time unless a market is currently open.',
            style: TextStyle(
                color: AppTheme.textSecondary, height: 1.6, fontSize: 14),
          ),
        ),
        const SizedBox(height: 16),
        GestureDetector(
          onTap: () => setState(() => _agreed = !_agreed),
          child: Row(
            children: [
              Checkbox(
                value: _agreed,
                onChanged: (v) => setState(() => _agreed = v ?? false),
                checkColor: Colors.white,
                fillColor: WidgetStateProperty.resolveWith(
                  (s) => s.contains(WidgetState.selected)
                      ? AppTheme.primary
                      : null,
                ),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'I understand and agree',
                  style: TextStyle(
                      color: AppTheme.textPrimary, fontSize: 14),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: _agreed ? () => setState(() => _step = 2) : null,
          child: const Text('Continue'),
        ),
      ],
    );
  }

  Widget _buildStep3(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Center(
          child: Icon(Icons.rocket_launch_outlined,
              size: 56, color: AppTheme.primary),
        ),
        const SizedBox(height: 16),
        const Text(
          'You\'re live as a Market Maker!',
          textAlign: TextAlign.center,
          style: TextStyle(
              fontSize: 20,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary),
        ),
        const SizedBox(height: 10),
        const Text(
          'Your profile is now public and bettable. The community can open prediction markets on your popularity.',
          textAlign: TextAlign.center,
          style: TextStyle(
              color: AppTheme.textSecondary, height: 1.5, fontSize: 14),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(_error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppTheme.danger, fontSize: 13)),
        ],
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: _isSubmitting ? null : _goLive,
          child: _isSubmitting
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Text('Let\'s Go'),
        ),
      ],
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
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text(
          title,
          style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary),
        ),
      );
}

class _TierBadge extends StatelessWidget {
  final String tier;
  const _TierBadge(this.tier);

  static const _labels = {
    'on_fire': 'On Fire',
    'rising': 'Rising',
    'watched': 'Watched',
    'listed': 'Listed',
  };

  static const _colors = {
    'on_fire': Color(0xFFFF6B2B),
    'rising': AppTheme.success,
    'watched': Color(0xFF4A9EFF),
    'listed': AppTheme.textSecondary,
  };

  @override
  Widget build(BuildContext context) {
    final label = _labels[tier] ?? tier;
    final color = _colors[tier] ?? AppTheme.textSecondary;
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
            color: color, fontSize: 12, fontWeight: FontWeight.bold),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// PLATFORM CONNECTION TILE
// ─────────────────────────────────────────────────────────────────────────────

class _PlatformConnectionTile extends ConsumerStatefulWidget {
  final String platform;
  final bool isStub;

  const _PlatformConnectionTile({
    required this.platform,
    this.isStub = false,
  });

  @override
  ConsumerState<_PlatformConnectionTile> createState() =>
      _PlatformConnectionTileState();
}

class _PlatformConnectionTileState
    extends ConsumerState<_PlatformConnectionTile> {
  bool _isLoading = false;

  static const _labels = {
    'youtube': 'YouTube',
    'twitch': 'Twitch',
    'tiktok': 'TikTok',
    'x': 'X',
    'instagram': 'Instagram',
    'kick': 'Kick',
  };

  static const _icons = {
    'youtube': Icons.play_circle_outline,
    'twitch': Icons.sports_esports_outlined,
    'tiktok': Icons.music_note_outlined,
    'x': Icons.alternate_email,
    'instagram': Icons.photo_camera_outlined,
    'kick': Icons.videogame_asset_outlined,
  };

  Future<void> _connect() async {
    setState(() => _isLoading = true);
    try {
      final user = Supabase.instance.client.auth.currentUser;
      if (user == null) throw Exception('Not authenticated');
      final res = await Supabase.instance.client.functions.invoke(
        'oauth-initiate',
        body: {'platform': widget.platform, 'user_id': user.id},
      );
      final authUrl = res.data['auth_url'] as String?;
      if (authUrl == null) throw Exception('No auth URL returned');
      await openUrlInBrowser(authUrl);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to connect: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _confirmDisconnect() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Disconnect',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          'Disconnect your ${_labels[widget.platform] ?? widget.platform} account?',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppTheme.danger),
            child: const Text('Disconnect'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    setState(() => _isLoading = true);
    try {
      await Supabase.instance.client.functions.invoke(
        'disconnect-platform',
        body: {'platform': widget.platform},
      );
      ref.invalidate(platformConnectionsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Failed to disconnect: $e'),
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final label = _labels[widget.platform] ?? widget.platform;
    final icon = _icons[widget.platform] ?? Icons.link;

    if (widget.isStub) {
      return OutlinedButton.icon(
        onPressed: () => ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Coming in a future update'),
            behavior: SnackBarBehavior.floating,
          ),
        ),
        icon: Icon(icon, size: 16),
        label: Text(label, style: const TextStyle(fontSize: 13)),
        style: OutlinedButton.styleFrom(
          foregroundColor: AppTheme.textSecondary,
          side: const BorderSide(color: AppTheme.cardBorder),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
      );
    }

    final connectionsAsync = ref.watch(platformConnectionsProvider);
    return connectionsAsync.when(
      loading: () => _buildTile(
          label: label, icon: icon, isConnected: false, username: null),
      error: (_, __) => _buildTile(
          label: label, icon: icon, isConnected: false, username: null),
      data: (connections) {
        final conn = connections
            .where((c) => c.platform == widget.platform && c.isActive)
            .firstOrNull;
        return _buildTile(
          label: label,
          icon: icon,
          isConnected: conn != null,
          username: conn?.platformUsername,
        );
      },
    );
  }

  Widget _buildTile({
    required String label,
    required IconData icon,
    required bool isConnected,
    required String? username,
  }) {
    return GestureDetector(
      onLongPress: isConnected ? _confirmDisconnect : null,
      child: OutlinedButton(
        onPressed: _isLoading
            ? null
            : isConnected
                ? null
                : _connect,
        style: OutlinedButton.styleFrom(
          foregroundColor:
              isConnected ? AppTheme.success : AppTheme.textSecondary,
          side: BorderSide(
            color: isConnected
                ? AppTheme.success.withValues(alpha: 0.5)
                : AppTheme.cardBorder,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        ),
        child: _isLoading
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(
                    strokeWidth: 2, color: AppTheme.primary),
              )
            : Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 16),
                  const SizedBox(width: 6),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(label,
                              style: const TextStyle(fontSize: 13)),
                          if (isConnected) ...[
                            const SizedBox(width: 5),
                            Container(
                              width: 7,
                              height: 7,
                              decoration: const BoxDecoration(
                                color: AppTheme.success,
                                shape: BoxShape.circle,
                              ),
                            ),
                          ],
                        ],
                      ),
                      if (isConnected && username != null)
                        Text(
                          '@$username',
                          style: const TextStyle(
                            fontSize: 10,
                            color: AppTheme.textSecondary,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }
}

class _InviteFriendsCard extends StatelessWidget {
  final String referralCode;
  const _InviteFriendsCard({required this.referralCode});

  String get _link => 'nora-platforms.vercel.app/join?ref=$referralCode';

  void _copyLink(BuildContext context) {
    Clipboard.setData(ClipboardData(text: 'https://$_link'));
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: const Text('Link copied!'),
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
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.secondary.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.secondary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.people_outline,
                    color: AppTheme.secondary, size: 20),
              ),
              const SizedBox(width: 12),
              const Text(
                'Invite Friends',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: 10),
          const Text(
            'Invite friends and earn 25 tokens for each signup',
            style: TextStyle(color: AppTheme.textSecondary, height: 1.4),
          ),
          const SizedBox(height: 14),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: AppTheme.background,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: AppTheme.cardBorder),
            ),
            child: Text(
              _link,
              style: const TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(height: 12),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _copyLink(context),
              icon: const Icon(Icons.copy_outlined, size: 16),
              label: const Text('Copy Link'),
              style: OutlinedButton.styleFrom(
                foregroundColor: AppTheme.secondary,
                side: BorderSide(
                    color: AppTheme.secondary.withValues(alpha: 0.5)),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
