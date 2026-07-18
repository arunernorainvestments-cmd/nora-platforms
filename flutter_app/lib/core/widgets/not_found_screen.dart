import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';

/// Themed 404 for unknown URLs (GoRouter errorBuilder) — replaces the stock
/// red "Page Not Found" error text with a branded dead-end + a way home.
class NotFoundScreen extends StatelessWidget {
  const NotFoundScreen({super.key, this.location});

  /// The path that failed to match, shown so a mistyped share link is obvious.
  final String? location;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.travel_explore,
                    size: 56, color: AppTheme.primary),
                const SizedBox(height: 16),
                const Text('This page doesn\'t exist',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 8),
                Text(
                  location == null || location!.isEmpty
                      ? 'The link may be old or mistyped.'
                      : 'Nothing lives at $location — the link may be old or '
                          'mistyped.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 14),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: () => context.go('/home'),
                  icon: const Icon(Icons.home_outlined),
                  label: const Text('Take me home'),
                ),
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () => context.go('/battle'),
                  child: const Text('Go to the Arena',
                      style: TextStyle(color: AppTheme.secondary)),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
