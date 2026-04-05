import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/referral_provider.dart';

class ReferralScreen extends ConsumerStatefulWidget {
  /// The raw ?ref= query param value — expected to be the referrer's username.
  final String? refParam;

  const ReferralScreen({super.key, this.refParam});

  @override
  ConsumerState<ReferralScreen> createState() => _ReferralScreenState();
}

class _ReferralScreenState extends ConsumerState<ReferralScreen> {
  bool _isLoading = false;
  String? _referrerUsername;

  @override
  void initState() {
    super.initState();
    if (widget.refParam != null && widget.refParam!.isNotEmpty) {
      _lookupReferrer(widget.refParam!);
    }
  }

  Future<void> _lookupReferrer(String username) async {
    setState(() => _isLoading = true);
    try {
      final data = await Supabase.instance.client
          .from('profiles')
          .select('username, referral_code')
          .eq('username', username)
          .maybeSingle();

      if (data != null && mounted) {
        final code = data['referral_code'] as String?;
        final uname = data['username'] as String? ?? username;
        if (code != null) {
          // Store for signup to consume
          ref.read(referralInfoProvider.notifier).state =
              ReferralInfo(code: code, username: uname);
          setState(() => _referrerUsername = uname);
        }
      }
    } catch (_) {
      // If lookup fails, fall through to generic invite UI
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Color _avatarColor(String name) {
    const palette = [
      Color(0xFF6C63FF), Color(0xFF00C896), Color(0xFFFF6B35),
      Color(0xFFEE1D52), Color(0xFF9146FF), Color(0xFFFFD700),
      Color(0xFF00BCD4),
    ];
    final index =
        name.codeUnits.fold(0, (sum, c) => sum + c) % palette.length;
    return palette[index];
  }

  @override
  Widget build(BuildContext context) {
    final displayName = _referrerUsername ?? widget.refParam;
    final color = displayName != null ? _avatarColor(displayName) : AppTheme.primary;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // ── N.O.R.A. wordmark ──────────────────────────────────────
                const Text(
                  'N.O.R.A.',
                  style: TextStyle(
                    color: AppTheme.primary,
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 4,
                  ),
                ),
                const SizedBox(height: 4),
                const Text(
                  'Platforms',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 13,
                    letterSpacing: 2,
                  ),
                ),
                const SizedBox(height: 48),

                // ── Invite card ────────────────────────────────────────────
                if (_isLoading)
                  const CircularProgressIndicator()
                else ...[
                  if (displayName != null) ...[
                    // Avatar
                    Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: color.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                        border: Border.all(
                            color: color.withValues(alpha: 0.5), width: 2),
                      ),
                      child: Center(
                        child: Text(
                          displayName[0].toUpperCase(),
                          style: TextStyle(
                            color: color,
                            fontSize: 30,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 20),
                    const Text(
                      "You've been invited by",
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '@$displayName',
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 16),
                  ] else ...[
                    const Icon(Icons.people_outline,
                        size: 72, color: AppTheme.primary),
                    const SizedBox(height: 20),
                    const Text(
                      "You've been invited to",
                      style: TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 15,
                      ),
                    ),
                    const SizedBox(height: 6),
                  ],
                  const Text(
                    'N.O.R.A. Platforms',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(16),
                    decoration: BoxDecoration(
                      color: AppTheme.primary.withValues(alpha: 0.08),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                          color: AppTheme.primary.withValues(alpha: 0.25)),
                    ),
                    child: const Row(
                      children: [
                        Text('🪙', style: TextStyle(fontSize: 20)),
                        SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            'Sign up and you\'ll both receive bonus tokens to start trading.',
                            style: TextStyle(
                              color: AppTheme.textPrimary,
                              fontSize: 13,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 40),

                // ── CTAs ───────────────────────────────────────────────────
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () => context.go('/signup'),
                    child: const Text('Sign Up'),
                  ),
                ),
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton(
                    onPressed: () => context.go('/login'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.textSecondary,
                      side: const BorderSide(color: AppTheme.cardBorder),
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                    ),
                    child: const Text('Sign In'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
