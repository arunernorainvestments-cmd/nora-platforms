import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';

class ForgotPasswordScreen extends StatefulWidget {
  const ForgotPasswordScreen({super.key});

  @override
  State<ForgotPasswordScreen> createState() => _ForgotPasswordScreenState();
}

class _ForgotPasswordScreenState extends State<ForgotPasswordScreen> {
  final _emailController = TextEditingController();
  bool _isLoading = false;
  String? _error;
  String? _success;

  @override
  void dispose() {
    _emailController.dispose();
    super.dispose();
  }

  Future<void> _sendResetLink() async {
    final email = _emailController.text.trim();
    if (email.isEmpty) {
      setState(() { _error = 'Please enter your email address.'; });
      return;
    }
    setState(() { _isLoading = true; _error = null; _success = null; });
    try {
      // redirectTo must be allowlisted in Supabase (Auth → URL Configuration).
      // Uri.base.origin keeps this correct across local dev and production.
      await Supabase.instance.client.auth.resetPasswordForEmail(
        email,
        redirectTo: '${Uri.base.origin}/update-password',
      );
      setState(() {
        _success = 'Check your email for a password reset link';
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
        title: const Text('Forgot Password'),
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: 40),
              const Text(
                'Reset Password',
                style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: AppTheme.textPrimary),
              ),
              const SizedBox(height: 8),
              const Text(
                'Enter your email to receive a reset link',
                style: TextStyle(color: AppTheme.textSecondary),
              ),
              const SizedBox(height: 40),
              TextField(
                controller: _emailController,
                keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(
                  labelText: 'Email',
                  prefixIcon:
                      Icon(Icons.email_outlined, color: AppTheme.textSecondary),
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
              if (_success != null) ...[
                const SizedBox(height: 12),
                Text(
                  _success!,
                  style: const TextStyle(color: AppTheme.success, fontSize: 13),
                  textAlign: TextAlign.center,
                ),
              ],
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: _isLoading ? null : _sendResetLink,
                child: _isLoading
                    ? const SizedBox(
                        height: 20,
                        width: 20,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Text('Send Reset Link'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
