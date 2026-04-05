import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/auth_provider.dart';

class SignupScreen extends ConsumerStatefulWidget {
  const SignupScreen({super.key});

  @override
  ConsumerState<SignupScreen> createState() => _SignupScreenState();
}

class _SignupScreenState extends ConsumerState<SignupScreen> {
  final _usernameController = TextEditingController();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String? _error;
  String? _success;
  String? _usernameError;

  @override
  void dispose() {
    _usernameController.dispose();
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// Returns an error string or null if valid.
  String? _validateUsername(String username) {
    if (username.isEmpty) return null; // optional
    if (username.length > 30) return 'Max 30 characters';
    if (!RegExp(r'^[a-z0-9_]+$').hasMatch(username)) {
      return 'Lowercase letters, numbers, and underscores only';
    }
    return null;
  }

  Future<bool> _isUsernameTaken(String username) async {
    final existing = await Supabase.instance.client
        .from('profiles')
        .select('id')
        .eq('username', username)
        .maybeSingle();
    return existing != null;
  }

  Future<void> _signUp() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _success = null;
      _usernameError = null;
    });

    try {
      final rawUsername = _usernameController.text.trim();
      final email = _emailController.text.trim();

      // Validate username format
      final formatError = _validateUsername(rawUsername);
      if (formatError != null) {
        setState(() {
          _usernameError = formatError;
          _isLoading = false;
        });
        return;
      }

      // Determine effective username
      final effectiveUsername = rawUsername.isNotEmpty
          ? rawUsername
          : email.contains('@')
              ? email.split('@').first.toLowerCase().replaceAll(
                  RegExp(r'[^a-z0-9_]'), '_')
              : '';

      // Check uniqueness
      if (effectiveUsername.isNotEmpty) {
        final taken = await _isUsernameTaken(effectiveUsername);
        if (taken) {
          setState(() {
            _usernameError = rawUsername.isNotEmpty
                ? 'Username is already taken'
                : 'Default username "$effectiveUsername" is taken — please choose one';
            _isLoading = false;
          });
          return;
        }
      }

      await ref.read(authActionsProvider).signUpWithEmail(
            email,
            _passwordController.text,
            username: effectiveUsername.isNotEmpty ? effectiveUsername : null,
          );

      setState(() {
        _success = 'Account created! Check your email to confirm.';
      });
    } catch (e) {
      setState(() { _error = e.toString(); });
    } finally {
      setState(() { _isLoading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.go('/login'),
        ),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 40),
              const Text('Create Account',
                style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary)),
              const SizedBox(height: 8),
              const Text('Join N.O.R.A. Platforms',
                style: TextStyle(color: AppTheme.textSecondary)),
              const SizedBox(height: 40),
              TextField(
                controller: _usernameController,
                keyboardType: TextInputType.text,
                autocorrect: false,
                decoration: InputDecoration(
                  hintText: 'Username (optional)',
                  prefixIcon: const Icon(Icons.alternate_email,
                      color: AppTheme.textSecondary),
                  errorText: _usernameError,
                ),
                onChanged: (_) {
                  if (_usernameError != null) {
                    setState(() { _usernameError = null; });
                  }
                },
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon: Icon(Icons.email_outlined, color: AppTheme.textSecondary),
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _passwordController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Password',
                  prefixIcon: Icon(Icons.lock_outline, color: AppTheme.textSecondary),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                  style: const TextStyle(color: AppTheme.danger, fontSize: 13),
                  textAlign: TextAlign.center),
              ],
              if (_success != null) ...[
                const SizedBox(height: 12),
                Text(_success!,
                  style: const TextStyle(color: AppTheme.success, fontSize: 13),
                  textAlign: TextAlign.center),
              ],
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isLoading ? null : _signUp,
                child: _isLoading
                    ? const SizedBox(height: 20, width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Create Account'),
              ),
              const SizedBox(height: 24),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Text('Already have an account? ',
                    style: TextStyle(color: AppTheme.textSecondary)),
                GestureDetector(
                  onTap: () => context.go('/login'),
                  child: const Text('Sign In',
                      style: TextStyle(color: AppTheme.primary, fontWeight: FontWeight.w600)),
                ),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}
