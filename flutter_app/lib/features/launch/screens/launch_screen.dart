import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/open_url.dart';
import '../../waitlist/models/waitlist_models.dart';
import '../../waitlist/providers/waitlist_provider.dart';

// Update this date before public launch.
final _launchDate = DateTime.utc(2026, 7, 4);

class LaunchScreen extends ConsumerStatefulWidget {
  // Populated when arriving via /w/:token. Null on the root / route.
  final String? referralToken;

  const LaunchScreen({super.key, this.referralToken});

  @override
  ConsumerState<LaunchScreen> createState() => _LaunchScreenState();
}

class _LaunchScreenState extends ConsumerState<LaunchScreen> {
  late Timer _timer;
  late Duration _remaining;

  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  bool _consentChecked = false;
  bool _isSubmitting = false;
  String? _submitError;

  @override
  void initState() {
    super.initState();
    _remaining = _launchDate.difference(DateTime.now().toUtc());
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _remaining = _launchDate.difference(DateTime.now().toUtc());
        });
      }
    });

    // Determine waitlist state from URL token or local storage.
    // Skip if state is already loaded (user navigated away and back).
    Future.microtask(() {
      if (!mounted) return;
      final current = ref.read(waitlistStateProvider);
      if (widget.referralToken != null) {
        // URL token always takes precedence — could be someone else's link.
        ref
            .read(waitlistStateProvider.notifier)
            .loadFromToken(widget.referralToken!);
      } else if (current is! WaitlistJoined && current is! WaitlistReturning) {
        ref.read(waitlistStateProvider.notifier).loadFromStorage();
      }
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    if (!_consentChecked) {
      setState(() => _submitError =
          'Please agree to the Terms of Service and Privacy Policy to continue.');
      return;
    }

    setState(() {
      _isSubmitting = true;
      _submitError = null;
    });

    try {
      await ref.read(waitlistStateProvider.notifier).signup(
            _emailController.text.trim().toLowerCase(),
            referralToken: widget.referralToken,
          );
      // Refresh count pill after signup.
      if (mounted) ref.invalidate(waitlistCountProvider);
    } catch (e) {
      if (mounted) {
        setState(() =>
            _submitError = "Couldn't reach the server. Please try again.");
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final countAsync = ref.watch(waitlistCountProvider);
    final waitlistState = ref.watch(waitlistStateProvider);
    final r = _remaining.isNegative ? Duration.zero : _remaining;

    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Stack(
        children: [
          const _Background(),
          SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 40),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  const SizedBox(height: 16),
                  _buildHeader(),
                  const SizedBox(height: 28),
                  _buildUserCount(countAsync),
                  const SizedBox(height: 32),
                  _buildCountdown(
                    r.inDays,
                    r.inHours % 24,
                    r.inMinutes % 60,
                    r.inSeconds % 60,
                  ),
                  const SizedBox(height: 24),
                  _buildExploreButton(context),
                  const SizedBox(height: 28),
                  _buildWaitlistSection(waitlistState),
                  const SizedBox(height: 32),
                  _buildAuthLinks(context),
                  const SizedBox(height: 32),
                  _buildFooter(context),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Waitlist section dispatch ──────────────────────────────────────────────

  Widget _buildWaitlistSection(WaitlistState state) {
    if (state is WaitlistLoading) return _buildLoadingState();
    if (state is WaitlistJoined) return _buildPositionCard(state.response);
    if (state is WaitlistReturning) return _buildPositionCard(state.response);
    return _buildForm();
  }

  Widget _buildLoadingState() {
    return const SizedBox(
      height: 120,
      child: Center(
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: AppTheme.primary,
        ),
      ),
    );
  }

  // ── State 1: Anonymous ─────────────────────────────────────────────────────

  Widget _buildForm() {
    return Form(
      key: _formKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextFormField(
            controller: _emailController,
            keyboardType: TextInputType.emailAddress,
            autocorrect: false,
            style: const TextStyle(color: Colors.white),
            decoration: InputDecoration(
              hintText: 'your@email.com',
              hintStyle:
                  TextStyle(color: Colors.white.withValues(alpha: 0.35)),
              filled: true,
              fillColor: AppTheme.surface,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                    color: AppTheme.cardBorder.withValues(alpha: 0.6)),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide: BorderSide(
                    color: AppTheme.cardBorder.withValues(alpha: 0.6)),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(14),
                borderSide:
                    const BorderSide(color: AppTheme.primary, width: 1.5),
              ),
              contentPadding:
                  const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
            ),
            validator: (v) {
              if (v == null || v.trim().isEmpty) {
                return 'Please enter your email';
              }
              if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                  .hasMatch(v.trim())) {
                return 'Please enter a valid email address';
              }
              return null;
            },
          ),
          const SizedBox(height: 16),
          GestureDetector(
            onTap: () =>
                setState(() => _consentChecked = !_consentChecked),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(
                  width: 24,
                  height: 24,
                  child: Checkbox(
                    value: _consentChecked,
                    onChanged: (v) =>
                        setState(() => _consentChecked = v ?? false),
                    activeColor: AppTheme.primary,
                    side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.4),
                        width: 1.5),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4)),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(child: _ConsentText()),
              ],
            ),
          ),
          if (_submitError != null) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                Expanded(
                  child: Text(
                    _submitError!,
                    style: const TextStyle(
                        color: AppTheme.danger, fontSize: 13, height: 1.4),
                  ),
                ),
                TextButton(
                  onPressed: _submit,
                  child: const Text('Retry',
                      style: TextStyle(color: AppTheme.primary, fontSize: 13)),
                ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          SizedBox(
            height: 52,
            child: ElevatedButton(
              onPressed: _isSubmitting ? null : _submit,
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                disabledBackgroundColor:
                    AppTheme.primary.withValues(alpha: 0.5),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: _isSubmitting
                  ? const SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
                    )
                  : const Text(
                      'JOIN THE WAITLIST',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        fontSize: 14,
                        letterSpacing: 1.5,
                      ),
                    ),
            ),
          ),
        ],
      ),
    );
  }

  // ── States 2 & 3: Joined / Returning ──────────────────────────────────────

  Widget _buildPositionCard(WaitlistResponse response) {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: AppTheme.success.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: AppTheme.success.withValues(alpha: 0.3), width: 1),
      ),
      child: Column(
        children: [
          const Text('🎉', style: TextStyle(fontSize: 40)),
          const SizedBox(height: 14),
          Text(
            response.isNewUser ? "You're on the list." : "You're already on the list.",
            style: const TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Your spot is #${_formatNumber(response.queuePosition)}',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.75),
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 24),
          _Divider(),
          const SizedBox(height: 20),
          Text(
            'Move up by sharing your link',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.55),
              fontSize: 13,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 12),
          _ReferralUrlDisplay(url: response.referralLink),
          const SizedBox(height: 20),
          _Divider(),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _StatChip(
                label: 'total signups',
                value: _formatNumber(response.totalCount),
              ),
              Container(
                width: 1,
                height: 28,
                margin: const EdgeInsets.symmetric(horizontal: 16),
                color: Colors.white.withValues(alpha: 0.15),
              ),
              _StatChip(
                label: 'your referrals',
                value: '${response.user.referralCount}',
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Shared widgets ──────────────────────────────────────────────────────────

  Widget _buildHeader() {
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [AppTheme.primary, Color(0xFF9C27B0)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(20),
            boxShadow: [
              BoxShadow(
                color: AppTheme.primary.withValues(alpha: 0.4),
                blurRadius: 24,
                spreadRadius: 2,
              ),
            ],
          ),
          child: const Center(
            child: Text(
              'N',
              style: TextStyle(
                color: Colors.white,
                fontSize: 36,
                fontWeight: FontWeight.w900,
                letterSpacing: -1,
              ),
            ),
          ),
        ),
        const SizedBox(height: 20),
        const Text(
          'N.O.R.A. PLATFORMS',
          style: TextStyle(
            color: Colors.white,
            fontSize: 26,
            fontWeight: FontWeight.w900,
            letterSpacing: 3,
          ),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 10),
        Text(
          'Predict the rise of creators.\nBe first. Be rewarded.',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.65),
            fontSize: 15,
            height: 1.5,
            letterSpacing: 0.3,
          ),
          textAlign: TextAlign.center,
        ),
      ],
    );
  }

  Widget _buildUserCount(AsyncValue<int> countAsync) {
    if (countAsync is AsyncLoading) return const SizedBox(height: 36);
    final raw = countAsync.valueOrNull ?? 0;
    final count = raw < 37 ? 37 : raw;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(40),
        border: Border.all(
          color: AppTheme.primary.withValues(alpha: 0.35),
          width: 1,
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('🔥', style: TextStyle(fontSize: 16)),
          const SizedBox(width: 8),
          RichText(
            text: TextSpan(
              style: const TextStyle(fontSize: 14),
              children: [
                TextSpan(
                  text: _formatCount(count),
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                TextSpan(
                  text: ' early members joined',
                  style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.75)),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCountdown(int days, int hours, int minutes, int seconds) {
    return Column(
      children: [
        Text(
          'LAUNCHING IN',
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 11,
            letterSpacing: 3,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _CountdownBox(value: days, label: 'DAYS'),
            const _CountdownSeparator(),
            _CountdownBox(value: hours, label: 'HRS'),
            const _CountdownSeparator(),
            _CountdownBox(value: minutes, label: 'MIN'),
            const _CountdownSeparator(),
            _CountdownBox(value: seconds, label: 'SEC'),
          ],
        ),
      ],
    );
  }

  Widget _buildExploreButton(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () => context.push('/hot-topic'),
      icon: const Text('🔥', style: TextStyle(fontSize: 14)),
      label: const Text(
        "SEE WHO'S HOT RIGHT NOW",
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 1,
        ),
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side:
            BorderSide(color: Colors.white.withValues(alpha: 0.25), width: 1),
        shape:
            RoundedRectangleBorder(borderRadius: BorderRadius.circular(40)),
        padding:
            const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      ),
    );
  }

  void _showBetaSheet(BuildContext context, String destination) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => _BetaConsentSheet(destination: destination),
    );
  }

  Widget _buildAuthLinks(BuildContext context) {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'Already have an account? ',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55), fontSize: 14),
            ),
            GestureDetector(
              onTap: () => _showBetaSheet(context, '/login'),
              child: const Text(
                'Sign in',
                style: TextStyle(
                  color: AppTheme.primary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              'New here? ',
              style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.55), fontSize: 14),
            ),
            GestureDetector(
              onTap: () => _showBetaSheet(context, '/signup'),
              child: const Text(
                'Create an account',
                style: TextStyle(
                  color: AppTheme.secondary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildFooter(BuildContext context) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        GestureDetector(
          onTap: () => openUrlInBrowser('https://noraplatforms.com/privacy'),
          child: Text(
            'Privacy Policy',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 12,
              decoration: TextDecoration.underline,
              decorationColor: Colors.white.withValues(alpha: 0.4),
            ),
          ),
        ),
        Text(
          '  ·  ',
          style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4), fontSize: 12),
        ),
        GestureDetector(
          onTap: () => openUrlInBrowser('https://noraplatforms.com/terms'),
          child: Text(
            'Terms of Service',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.4),
              fontSize: 12,
              decoration: TextDecoration.underline,
              decorationColor: Colors.white.withValues(alpha: 0.4),
            ),
          ),
        ),
      ],
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  String _formatCount(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }

  String _formatNumber(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return n.toString();
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// REFERRAL URL DISPLAY
// ─────────────────────────────────────────────────────────────────────────────

class _ReferralUrlDisplay extends StatefulWidget {
  final String url;
  const _ReferralUrlDisplay({required this.url});

  @override
  State<_ReferralUrlDisplay> createState() => _ReferralUrlDisplayState();
}

class _ReferralUrlDisplayState extends State<_ReferralUrlDisplay> {
  bool _copied = false;

  Future<void> _copy() async {
    await Clipboard.setData(ClipboardData(text: widget.url));
    setState(() => _copied = true);
    await Future.delayed(const Duration(seconds: 2));
    if (mounted) setState(() => _copied = false);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border:
            Border.all(color: AppTheme.cardBorder.withValues(alpha: 0.7)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
              child: SelectableText(
                widget.url,
                style: TextStyle(
                  color: Colors.white.withValues(alpha: 0.85),
                  fontSize: 13,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
          GestureDetector(
            onTap: _copy,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: _copied
                    ? AppTheme.success.withValues(alpha: 0.2)
                    : AppTheme.primary.withValues(alpha: 0.15),
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(11),
                  bottomRight: Radius.circular(11),
                ),
                border: Border(
                  left: BorderSide(
                      color: AppTheme.cardBorder.withValues(alpha: 0.7)),
                ),
              ),
              child: Text(
                _copied ? 'Copied!' : 'Copy',
                style: TextStyle(
                  color: _copied ? AppTheme.success : AppTheme.primary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// STAT CHIP
// ─────────────────────────────────────────────────────────────────────────────

class _StatChip extends StatelessWidget {
  final String value;
  final String label;
  const _StatChip({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text(
          value,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 20,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          label,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.5),
            fontSize: 12,
          ),
        ),
      ],
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      color: Colors.white.withValues(alpha: 0.08),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CONSENT TEXT
// ─────────────────────────────────────────────────────────────────────────────

class _ConsentText extends StatelessWidget {
  const _ConsentText();

  @override
  Widget build(BuildContext context) {
    final dimWhite = Colors.white.withValues(alpha: 0.55);
    final linkStyle = TextStyle(
      color: Colors.white.withValues(alpha: 0.85),
      fontSize: 13,
      decoration: TextDecoration.underline,
      decorationColor: Colors.white.withValues(alpha: 0.55),
    );

    return RichText(
      text: TextSpan(
        style: TextStyle(color: dimWhite, fontSize: 13, height: 1.5),
        children: [
          const TextSpan(text: 'By signing up you agree to our '),
          TextSpan(
            text: 'Terms of Service',
            style: linkStyle,
            recognizer: TapGestureRecognizer()
              ..onTap =
                  () => openUrlInBrowser('https://noraplatforms.com/terms'),
          ),
          const TextSpan(text: ' and '),
          TextSpan(
            text: 'Privacy Policy',
            style: linkStyle,
            recognizer: TapGestureRecognizer()
              ..onTap = () =>
                  openUrlInBrowser('https://noraplatforms.com/privacy'),
          ),
          const TextSpan(text: '.'),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// COUNTDOWN BOX
// ─────────────────────────────────────────────────────────────────────────────

class _CountdownBox extends StatelessWidget {
  final int value;
  final String label;

  const _CountdownBox({required this.value, required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 68,
      padding: const EdgeInsets.symmetric(vertical: 14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
            color: AppTheme.cardBorder.withValues(alpha: 0.8), width: 1),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        children: [
          Text(
            value.toString().padLeft(2, '0'),
            style: const TextStyle(
              color: Colors.white,
              fontSize: 28,
              fontWeight: FontWeight.w800,
              height: 1,
            ),
          ),
          const SizedBox(height: 5),
          Text(
            label,
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 10,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}

class _CountdownSeparator extends StatelessWidget {
  const _CountdownSeparator();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        ':',
        style: TextStyle(
          color: Colors.white.withValues(alpha: 0.4),
          fontSize: 24,
          fontWeight: FontWeight.w300,
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BETA CONSENT SHEET
// Direct insert path — referral_token is auto-generated by the DB DEFAULT
// (generate_waitlist_token() set in migration 042). Fire-and-forget; does not
// show waitlist position since the sheet's purpose is navigating to login/signup.
// ─────────────────────────────────────────────────────────────────────────────

class _BetaConsentSheet extends StatefulWidget {
  final String destination;
  const _BetaConsentSheet({required this.destination});

  @override
  State<_BetaConsentSheet> createState() => _BetaConsentSheetState();
}

class _BetaConsentSheetState extends State<_BetaConsentSheet> {
  final _emailController = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _consentChecked = false;
  bool _isSubmitting = false;
  bool _registered = false;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _registerBeta() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isSubmitting = true);
    try {
      await Supabase.instance.client
          .from('waitlist')
          .insert({
            'email': _emailController.text.trim().toLowerCase(),
            'source': 'flutter_beta_sheet',
          });
      if (mounted) setState(() => _registered = true);
    } on PostgrestException catch (e) {
      if (mounted && e.code == '23505') setState(() => _registered = true);
    } catch (_) {
      // fire-and-forget — don't block navigation on failure
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      padding: EdgeInsets.only(
        left: 28,
        right: 28,
        top: 28,
        bottom: MediaQuery.of(context).viewInsets.bottom + 36,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Center(
            child: Container(
              width: 40,
              height: 4,
              decoration: BoxDecoration(
                color: AppTheme.cardBorder,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
          ),
          const SizedBox(height: 24),
          const Row(
            children: [
              Text('🚀', style: TextStyle(fontSize: 28)),
              SizedBox(width: 12),
              Expanded(
                child: Text(
                  "You're entering Beta",
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            'N.O.R.A. Platforms officially launches on July 4th, 2026. '
            'By continuing, you\'re accessing an early beta version of the app. '
            'Some features may be incomplete, and you\'re likely to encounter '
            'more bugs and rough edges than you\'ll see after launch. '
            'We appreciate your patience — your feedback helps us build something great.',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.7),
              fontSize: 14,
              height: 1.6,
            ),
          ),
          const SizedBox(height: 28),
          Text(
            'WANT TO BE AN OFFICIAL BETA TESTER?',
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.45),
              fontSize: 11,
              letterSpacing: 1.5,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 12),
          if (_registered)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: AppTheme.success.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                    color: AppTheme.success.withValues(alpha: 0.3)),
              ),
              child: Row(
                children: [
                  const Text('✅', style: TextStyle(fontSize: 18)),
                  const SizedBox(width: 10),
                  Text(
                    "You're registered as a beta tester!",
                    style: TextStyle(
                      color: Colors.white.withValues(alpha: 0.85),
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            )
          else
            Form(
              key: _formKey,
              child: Column(
                children: [
                  GestureDetector(
                    onTap: () =>
                        setState(() => _consentChecked = !_consentChecked),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        SizedBox(
                          width: 24,
                          height: 24,
                          child: Checkbox(
                            value: _consentChecked,
                            onChanged: (v) =>
                                setState(() => _consentChecked = v ?? false),
                            activeColor: AppTheme.primary,
                            side: BorderSide(
                                color: Colors.white.withValues(alpha: 0.4),
                                width: 1.5),
                            shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(4)),
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            'I understand this is a beta version and I\'d like to register as an official beta tester.',
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.65),
                              fontSize: 13,
                              height: 1.5,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_consentChecked) ...[
                    const SizedBox(height: 14),
                    TextFormField(
                      controller: _emailController,
                      keyboardType: TextInputType.emailAddress,
                      autocorrect: false,
                      style: const TextStyle(color: Colors.white),
                      decoration: InputDecoration(
                        hintText: 'your@email.com',
                        hintStyle: TextStyle(
                            color: Colors.white.withValues(alpha: 0.35)),
                        filled: true,
                        fillColor: AppTheme.surfaceLight,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                              color:
                                  AppTheme.cardBorder.withValues(alpha: 0.6)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                              color:
                                  AppTheme.cardBorder.withValues(alpha: 0.6)),
                        ),
                        focusedBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: const BorderSide(
                              color: AppTheme.primary, width: 1.5),
                        ),
                        contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16, vertical: 14),
                      ),
                      validator: (v) {
                        if (v == null || v.trim().isEmpty) {
                          return 'Please enter your email';
                        }
                        if (!RegExp(r'^[^\s@]+@[^\s@]+\.[^\s@]+$')
                            .hasMatch(v.trim())) {
                          return 'Please enter a valid email';
                        }
                        return null;
                      },
                    ),
                    const SizedBox(height: 12),
                    SizedBox(
                      width: double.infinity,
                      height: 46,
                      child: OutlinedButton(
                        onPressed: _isSubmitting ? null : _registerBeta,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.primary,
                          side: const BorderSide(color: AppTheme.primary),
                          shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12)),
                        ),
                        child: _isSubmitting
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: AppTheme.primary),
                              )
                            : const Text(
                                'REGISTER AS BETA TESTER',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 13,
                                  letterSpacing: 1,
                                ),
                              ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          const SizedBox(height: 24),
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: () {
                Navigator.of(context).pop();
                context.push(widget.destination);
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: AppTheme.primary,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14)),
                elevation: 0,
              ),
              child: Text(
                widget.destination == '/login'
                    ? 'CONTINUE TO SIGN IN'
                    : 'CONTINUE TO CREATE ACCOUNT',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                  letterSpacing: 1.2,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// BACKGROUND
// ─────────────────────────────────────────────────────────────────────────────

class _Background extends StatelessWidget {
  const _Background();

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        Image.asset(
          'assets/images/launch_bg.png',
          fit: BoxFit.cover,
        ),
        Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [
                Color(0xAA0E0B1F),
                Color(0xCC050508),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
