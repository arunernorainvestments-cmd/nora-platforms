import 'dart:async';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/open_url.dart';

// Update this date before public launch.
final _launchDate = DateTime.utc(2026, 7, 4);

final _waitlistCountProvider = FutureProvider<int>((ref) async {
  final res = await Supabase.instance.client
      .from('waitlist')
      .select()
      .count(CountOption.exact);
  return res.count;
});

class LaunchScreen extends ConsumerStatefulWidget {
  const LaunchScreen({super.key});

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
  bool _submitted = false;
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
      await Supabase.instance.client.from('waitlist').insert({
        'email': _emailController.text.trim().toLowerCase(),
        'source': 'flutter_launch',
      });
      if (mounted) {
        setState(() => _submitted = true);
        ref.invalidate(_waitlistCountProvider);
      }
    } on PostgrestException catch (e) {
      if (mounted) {
        // Unique violation — already on the list, treat as success.
        if (e.code == '23505') {
          setState(() => _submitted = true);
        } else {
          setState(() => _submitError = 'Something went wrong. Please try again.');
        }
      }
    } catch (_) {
      if (mounted) {
        setState(() => _submitError = 'Something went wrong. Please try again.');
      }
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final countAsync = ref.watch(_waitlistCountProvider);
    final r = _remaining.isNegative ? Duration.zero : _remaining;
    final days = r.inDays;
    final hours = r.inHours % 24;
    final minutes = r.inMinutes % 60;
    final seconds = r.inSeconds % 60;

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
                  _buildCountdown(days, hours, minutes, seconds),
                  const SizedBox(height: 24),
                  _buildExploreButton(context),
                  const SizedBox(height: 28),
                  _submitted ? _buildSuccessState() : _buildForm(),
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

  Widget _buildHeader() {
    return Column(
      children: [
        // Logo placeholder — swap in asset image later
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
    final count = raw < 37 ? 37 : raw; // floor removed once organic signups exceed 37
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
                    color: Colors.white.withValues(alpha: 0.75),
                  ),
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
              hintStyle: TextStyle(color: Colors.white.withValues(alpha: 0.35)),
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
              contentPadding: const EdgeInsets.symmetric(
                  horizontal: 18, vertical: 16),
            ),
            validator: (v) {
              if (v == null || v.trim().isEmpty) return 'Please enter your email';
              final emailRegex =
                  RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$');
              if (!emailRegex.hasMatch(v.trim())) {
                return 'Please enter a valid email address';
              }
              return null;
            },
          ),
          const SizedBox(height: 16),
          // GDPR / CCPA consent — unchecked by default, required
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
                        color: Colors.white.withValues(alpha: 0.4), width: 1.5),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(4)),
                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
                const SizedBox(width: 10),
                const Expanded(
                  child: _ConsentText(),
                ),
              ],
            ),
          ),
          if (_submitError != null) ...[
            const SizedBox(height: 12),
            Text(
              _submitError!,
              style: const TextStyle(
                  color: AppTheme.danger, fontSize: 13, height: 1.4),
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

  Widget _buildSuccessState() {
    return Container(
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: AppTheme.success.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: AppTheme.success.withValues(alpha: 0.3), width: 1),
      ),
      child: Column(
        children: [
          const Text('🎉', style: TextStyle(fontSize: 40)),
          const SizedBox(height: 14),
          const Text(
            "You're on the list!",
            style: TextStyle(
              color: Colors.white,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            "We'll reach out when N.O.R.A. Platforms goes live.",
            style: TextStyle(
              color: Colors.white.withValues(alpha: 0.65),
              fontSize: 14,
              height: 1.5,
            ),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildExploreButton(BuildContext context) {
    return OutlinedButton.icon(
      onPressed: () => context.push('/explore'),
      icon: const Text('🔥', style: TextStyle(fontSize: 14)),
      label: const Text(
        'SEE WHO\'S HOT RIGHT NOW',
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          letterSpacing: 1,
        ),
      ),
      style: OutlinedButton.styleFrom(
        foregroundColor: Colors.white,
        side: BorderSide(color: Colors.white.withValues(alpha: 0.25), width: 1),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(40)),
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
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
          style:
              TextStyle(color: Colors.white.withValues(alpha: 0.4), fontSize: 12),
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

  String _formatCount(int n) {
    if (n >= 1000000) return '${(n / 1000000).toStringAsFixed(1)}M';
    if (n >= 1000) return '${(n / 1000).toStringAsFixed(1)}K';
    return '$n';
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// CONSENT TEXT — inline RichText with tappable links
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
              ..onTap = () => openUrlInBrowser('https://noraplatforms.com/terms'),
          ),
          const TextSpan(text: ' and '),
          TextSpan(
            text: 'Privacy Policy',
            style: linkStyle,
            recognizer: TapGestureRecognizer()
              ..onTap = () => openUrlInBrowser('https://noraplatforms.com/privacy'),
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
            'source': 'flutter_launch',
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
                              color: AppTheme.cardBorder.withValues(alpha: 0.6)),
                        ),
                        enabledBorder: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(12),
                          borderSide: BorderSide(
                              color: AppTheme.cardBorder.withValues(alpha: 0.6)),
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
                        if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$')
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
        // Dark overlay so text stays legible
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
