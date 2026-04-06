import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/providers/auth_provider.dart';
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
  bool _isBecomingCreator = false;

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

  Future<void> _becomeCreator() async {
    setState(() { _isBecomingCreator = true; });
    try {
      await ref.read(profileActionsProvider).becomeCreator();
      ref.invalidate(userProfileProvider);
      ref.invalidate(spotlightTierProvider);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Welcome to the creator community!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error: $e')),
        );
      }
    } finally {
      if (mounted) setState(() { _isBecomingCreator = false; });
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
                    color: AppTheme.primary.withValues(alpha:0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: AppTheme.primary.withValues(alpha:0.4)),
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

                // ── Creator section ───────────────────────────────────────
                if (!profile.isCreator)
                  _BecomeCreatorCard(
                    isLoading: _isBecomingCreator,
                    onTap: _becomeCreator,
                  )
                else
                  _CreatorDashboardCard(
                    tierAsync: tierAsync,
                    onSocialConnect: (platform) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                              'Social connections coming in Phase 3'),
                        ),
                      );
                    },
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
// WIDGETS
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

class _BecomeCreatorCard extends StatelessWidget {
  final bool isLoading;
  final VoidCallback onTap;

  const _BecomeCreatorCard({required this.isLoading, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.primary.withValues(alpha:0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha:0.15),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: const Icon(Icons.star_outline,
                    color: AppTheme.primary, size: 22),
              ),
              const SizedBox(width: 12),
              const Text(
                'Become a Creator',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            'Connect your social accounts and let the community bet on your popularity. Get discovered.',
            style: TextStyle(color: AppTheme.textSecondary, height: 1.5),
          ),
          const SizedBox(height: 16),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: isLoading ? null : onTap,
              child: isLoading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white))
                  : const Text('Claim Your Spot'),
            ),
          ),
        ],
      ),
    );
  }
}

class _CreatorDashboardCard extends StatelessWidget {
  final AsyncValue<String?> tierAsync;
  final void Function(String platform) onSocialConnect;

  const _CreatorDashboardCard(
      {required this.tierAsync, required this.onSocialConnect});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.secondary.withValues(alpha:0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Creator Dashboard',
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
          const SizedBox(height: 20),
          const Text(
            'Connect Social Accounts',
            style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: AppTheme.textSecondary),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              _SocialButton('YouTube', Icons.play_circle_outline,
                  () => onSocialConnect('youtube')),
              _SocialButton('TikTok', Icons.music_note_outlined,
                  () => onSocialConnect('tiktok')),
              _SocialButton('X', Icons.alternate_email,
                  () => onSocialConnect('x')),
              _SocialButton('Instagram', Icons.photo_camera_outlined,
                  () => onSocialConnect('instagram')),
              _SocialButton('Kick', Icons.sports_esports_outlined,
                  () => onSocialConnect('kick')),
              _SocialButton('Pinterest', Icons.push_pin_outlined,
                  () => onSocialConnect('pinterest')),
            ],
          ),
        ],
      ),
    );
  }
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
        color: color.withValues(alpha:0.15),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: color.withValues(alpha:0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(
            color: color, fontSize: 12, fontWeight: FontWeight.bold),
      ),
    );
  }
}

class _SocialButton extends StatelessWidget {
  final String platform;
  final IconData icon;
  final VoidCallback onTap;

  const _SocialButton(this.platform, this.icon, this.onTap);

  @override
  Widget build(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: onTap,
      icon: Icon(icon, size: 16),
      label: Text(platform, style: const TextStyle(fontSize: 13)),
      style: OutlinedButton.styleFrom(
        foregroundColor: AppTheme.textSecondary,
        side: const BorderSide(color: AppTheme.cardBorder),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }
}

class _InviteFriendsCard extends StatelessWidget {
  final String referralCode;
  const _InviteFriendsCard({required this.referralCode});

  String get _link =>
      'nora-platforms.vercel.app/join?ref=$referralCode';

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
                side: BorderSide(color: AppTheme.secondary.withValues(alpha: 0.5)),
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
