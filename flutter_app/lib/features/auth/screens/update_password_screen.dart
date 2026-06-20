import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/auth_provider.dart';

// Landing screen for the password-reset link (redirectTo target).
//
// Two recovery transports are supported, because Supabase can deliver the
// recovery in two shapes depending on the email template:
//
//  1. PKCE code  — link returns to `/update-password?code=...`. supabase_flutter
//     auto-exchanges it during Supabase.initialize and emits passwordRecovery.
//     Requires the link to be opened in the SAME browser that requested it
//     (the code-verifier lives in local storage).
//
//  2. token_hash — link returns to `/update-password?token_hash=...&type=recovery`
//     (email template uses {{ .TokenHash }}). We call verifyOTP() ourselves.
//     This works cross-device AND is not consumed by email link-scanners /
//     prefetchers, which spend the one-time token on the older /auth/v1/verify
//     style links and make a fresh link read as "expired". Prefer this template.
//
// The screen is reactive: it watches auth state and shows a "verifying" spinner
// while the recovery session is being established, the set-password form once a
// session exists, and an accurate "link expired" state only after verification
// has actually finished and failed (or the URL carried an auth error).
class UpdatePasswordScreen extends ConsumerStatefulWidget {
  const UpdatePasswordScreen({super.key});

  @override
  ConsumerState<UpdatePasswordScreen> createState() =>
      _UpdatePasswordScreenState();
}

class _UpdatePasswordScreenState extends ConsumerState<UpdatePasswordScreen> {
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  bool _isLoading = false;
  bool _obscure = true;
  String? _error;

  // Recovery-link verification state (distinct from the form's _error).
  bool _verifying = false; // token_hash verifyOTP() in flight
  bool _verifyAttempted = false; // token_hash verifyOTP() has completed
  String? _linkError; // human-readable reason the link is unusable

  @override
  void initState() {
    super.initState();
    _resolveRecoveryLink();
  }

  @override
  void dispose() {
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  // Inspect the URL the reset link landed on and establish a recovery session
  // when the link carries a token_hash. The PKCE (?code=) path is handled
  // automatically by supabase_flutter during init, so we only react to it.
  Future<void> _resolveRecoveryLink() async {
    final params = Uri.base.queryParameters;

    // Supabase appends an error when the link is invalid/expired/not allowed.
    final errorDescription = params['error_description'];
    if (errorDescription != null) {
      setState(() => _linkError =
          _humanizeError(params['error_code'], errorDescription));
      return;
    }

    final tokenHash = params['token_hash'];
    final type = params['type'];
    if (tokenHash != null && type == 'recovery') {
      setState(() => _verifying = true);
      try {
        await Supabase.instance.client.auth.verifyOTP(
          type: OtpType.recovery,
          tokenHash: tokenHash,
        );
        // verifyOTP emits passwordRecovery; mirror the latch so the router pin
        // (and our build below) treat this as an active recovery session.
        ref.read(passwordRecoveryProvider.notifier).state = true;
      } catch (e) {
        if (mounted) {
          setState(() => _linkError = _humanizeError(null, e.toString()));
        }
      } finally {
        if (mounted) {
          setState(() {
            _verifying = false;
            _verifyAttempted = true;
          });
        }
      }
    }
  }

  String _humanizeError(String? code, String raw) {
    final lower = '${code ?? ''} $raw'.toLowerCase();
    if (lower.contains('expired') ||
        lower.contains('otp_expired') ||
        lower.contains('invalid') ||
        lower.contains('not found') ||
        lower.contains('code verifier')) {
      return 'This password reset link is no longer valid — it has expired or '
          'already been used. Reset links are single-use and short-lived. '
          'Request a fresh one below and open it right away.';
    }
    return raw;
  }

  Future<void> _updatePassword() async {
    final password = _passwordController.text;
    final confirm = _confirmController.text;

    if (password.length < 8) {
      setState(() => _error = 'Password must be at least 8 characters.');
      return;
    }
    if (password != confirm) {
      setState(() => _error = 'Passwords do not match.');
      return;
    }

    setState(() {
      _isLoading = true;
      _error = null;
    });
    try {
      await Supabase.instance.client.auth.updateUser(
        UserAttributes(password: password),
      );
      // Recovery complete — release the router pin and continue into the app.
      ref.read(passwordRecoveryProvider.notifier).state = false;
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Password updated. You are signed in.')),
      );
      context.go('/home');
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch auth state so the screen rebuilds when the PKCE (?code=) exchange
    // finishes (or fails) during/after init — without this the screen would be
    // frozen in whatever state it first rendered.
    final authState = ref.watch(authStateProvider);
    final session = Supabase.instance.client.auth.currentSession;

    final params = Uri.base.queryParameters;
    final hasCode = params['code'] != null; // PKCE exchange (may be in flight)
    final hasTokenHash = params['token_hash'] != null;

    Widget body;
    if (_linkError != null) {
      // Explicit, known failure — show it even if a stale session lingers, so
      // the user never thinks they reset the password when they didn't.
      body = _buildExpired(_linkError);
    } else if (session != null) {
      // Live recovery (or existing) session — safe to set a new password.
      body = _buildForm();
    } else if (_verifying ||
        (hasTokenHash && !_verifyAttempted) ||
        (hasCode && authState.isLoading)) {
      // Verification still in flight (token_hash verifyOTP, or the automatic
      // PKCE ?code= exchange that supabase_flutter runs during init).
      body = _buildVerifying();
    } else if (authState.hasError) {
      body = _buildExpired(_humanizeError(null, authState.error.toString()));
    } else {
      body = _buildExpired(null);
    }

    return Scaffold(
      appBar: AppBar(title: const Text('Set New Password')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: body,
        ),
      ),
    );
  }

  Widget _buildVerifying() {
    return const Padding(
      padding: EdgeInsets.only(top: 80),
      child: Column(
        children: [
          CircularProgressIndicator(color: AppTheme.primary),
          SizedBox(height: 24),
          Text(
            'Verifying your reset link…',
            style: TextStyle(color: AppTheme.textSecondary),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }

  Widget _buildForm() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        const Text(
          'Choose a new password',
          style: TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary),
        ),
        const SizedBox(height: 8),
        const Text(
          'Enter and confirm your new password.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        const SizedBox(height: 40),
        TextField(
          controller: _passwordController,
          obscureText: _obscure,
          decoration: InputDecoration(
            labelText: 'New password',
            prefixIcon: const Icon(Icons.lock_outline,
                color: AppTheme.textSecondary),
            suffixIcon: IconButton(
              icon: Icon(
                _obscure ? Icons.visibility_off : Icons.visibility,
                color: AppTheme.textSecondary,
              ),
              onPressed: () => setState(() => _obscure = !_obscure),
            ),
          ),
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _confirmController,
          obscureText: _obscure,
          onSubmitted: (_) => _isLoading ? null : _updatePassword(),
          decoration: const InputDecoration(
            labelText: 'Confirm new password',
            prefixIcon:
                Icon(Icons.lock_outline, color: AppTheme.textSecondary),
          ),
        ),
        if (_error != null) ...[
          const SizedBox(height: 12),
          Text(
            _error!,
            style: const TextStyle(color: AppTheme.danger, fontSize: 13),
            textAlign: TextAlign.center,
          ),
        ],
        const SizedBox(height: 24),
        ElevatedButton(
          onPressed: _isLoading ? null : _updatePassword,
          child: _isLoading
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(
                      strokeWidth: 2, color: Colors.white))
              : const Text('Update Password'),
        ),
      ],
    );
  }

  Widget _buildExpired(String? message) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: 24),
        const Icon(Icons.link_off, size: 56, color: AppTheme.danger),
        const SizedBox(height: 16),
        const Text(
          'Reset link expired',
          style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: AppTheme.textPrimary),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 8),
        Text(
          message ??
              'This password reset link is invalid or has already been used. '
                  'Request a fresh one and open it promptly.',
          style: const TextStyle(color: AppTheme.textSecondary),
          textAlign: TextAlign.center,
        ),
        const SizedBox(height: 32),
        ElevatedButton(
          onPressed: () => context.go('/forgot-password'),
          child: const Text('Request a new link'),
        ),
        const SizedBox(height: 12),
        TextButton(
          onPressed: () => context.go('/login'),
          child: const Text('Back to login'),
        ),
      ],
    );
  }
}
