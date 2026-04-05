import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/providers/auth_provider.dart';

class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Profile')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(children: [
          const SizedBox(height: 20),
          CircleAvatar(
            radius: 48,
            backgroundColor: AppTheme.primary,
            child: Text(
              (user?.email?[0] ?? 'U').toUpperCase(),
              style: const TextStyle(fontSize: 36, color: Colors.white,
                  fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 16),
          Text(user?.email ?? 'User',
            style: const TextStyle(fontSize: 18, color: AppTheme.textPrimary,
                fontWeight: FontWeight.w600)),
          const SizedBox(height: 32),
          const Text('Connected Accounts',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold,
                color: AppTheme.textPrimary)),
          const SizedBox(height: 12),
          const Text('Social connections coming in Phase 2',
            style: TextStyle(color: AppTheme.textSecondary)),
          const Spacer(),
          ElevatedButton.icon(
            onPressed: () => ref.read(authActionsProvider).signOut(),
            icon: const Icon(Icons.logout),
            label: const Text('Sign Out'),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.danger,
              minimumSize: const Size(double.infinity, 50),
            ),
          ),
        ]),
      ),
    );
  }
}