import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/auth_provider.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});
  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  bool _isLoading = false;
  String? _error;

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    setState(() { _isLoading = true; _error = null; });
    try {
      await ref.read(authActionsProvider).signInWithEmail(
        _emailController.text.trim(),
        _passwordController.text,
      );
    } catch (e) {
      setState(() { _error = e.toString(); });
    } finally {
      setState(() { _isLoading = false; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 60),
              const Text('N.O.R.A.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 48, fontWeight: FontWeight.bold,
                    color: AppTheme.primary, letterSpacing: 8)),
              const Text('PLATFORMS',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: AppTheme.textSecondary, letterSpacing: 6)),
              const SizedBox(height: 8),
              const Text('Predict. Earn. Discover.',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: AppTheme.textSecondary)),
              const SizedBox(height: 60),
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
              Align(
                alignment: Alignment.centerRight,
                child: GestureDetector(
                  onTap: () => context.go('/forgot-password'),
                  child: const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text(
                      'Forgot password?',
                      style: TextStyle(color: AppTheme.primary, fontSize: 13),
                    ),
                  ),
                ),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                  style: const TextStyle(color: AppTheme.danger, fontSize: 13),
                  textAlign: TextAlign.center),
              ],
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isLoading ? null : _signIn,
                child: _isLoading
                    ? const SizedBox(height: 20, width: 20,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Text('Sign In'),
              ),
              const SizedBox(height: 16),
              const Row(children: [
                Expanded(child: Divider(color: AppTheme.cardBorder)),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16),
                  child: Text('or', style: TextStyle(color: AppTheme.textSecondary)),
                ),
                Expanded(child: Divider(color: AppTheme.cardBorder)),
              ]),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                onPressed: () => ref.read(authActionsProvider).signInWithGoogle(),
                icon: const Icon(Icons.g_mobiledata, size: 24),
                label: const Text('Continue with Google'),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppTheme.textPrimary,
                  side: const BorderSide(color: AppTheme.cardBorder),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
              ),
              const SizedBox(height: 24),
              Row(mainAxisAlignment: MainAxisAlignment.center, children: [
                const Text("Don't have an account? ",
                    style: TextStyle(color: AppTheme.textSecondary)),
                GestureDetector(
                  onTap: () => context.go('/signup'),
                  child: const Text('Sign Up',
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
