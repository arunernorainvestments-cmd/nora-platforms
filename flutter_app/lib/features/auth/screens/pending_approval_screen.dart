import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../providers/auth_provider.dart';

class PendingApprovalScreen extends ConsumerWidget {
  const PendingApprovalScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: const Color(0xFF0A0A0F),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.lock_clock_outlined,
                  size: 72, color: Color(0xFF6C63FF)),
              const SizedBox(height: 32),
              const Text(
                'Application Under Review',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 24,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.5,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Thanks for signing up for the N.O.R.A. Platforms beta. '
                'Your application is pending review by our team.\n\n'
                'We\'ll send you an email when your account is approved.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Color(0xFF8B8FA8),
                  fontSize: 15,
                  height: 1.6,
                ),
              ),
              const SizedBox(height: 48),
              OutlinedButton(
                onPressed: () =>
                    ref.read(authActionsProvider).signOut(),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF8B8FA8),
                  side: const BorderSide(color: Color(0xFF2A2A3E)),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12)),
                  padding: const EdgeInsets.symmetric(
                      horizontal: 32, vertical: 14),
                ),
                child: const Text('Sign Out'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
