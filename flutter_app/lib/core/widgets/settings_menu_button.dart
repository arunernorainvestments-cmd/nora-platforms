import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../theme/app_theme.dart';
import '../../features/auth/providers/auth_provider.dart';
import '../../features/settings/widgets/settings_overlay.dart';
import '../../features/settings/widgets/help_overlay.dart';

/// Whether the signed-in user is a platform admin (profiles.is_admin). Only
/// gates VISIBILITY of the console entry — the admin-review edge function
/// re-checks the flag server-side on every call.
final isAdminProvider = FutureProvider.autoDispose<bool>((ref) async {
  final user = ref.watch(currentUserProvider);
  if (user == null) return false;
  final row = await Supabase.instance.client
      .from('profiles')
      .select('is_admin')
      .eq('id', user.id)
      .maybeSingle();
  return row?['is_admin'] == true;
});

/// Sandwich (hamburger) icon in the AppBar. Opens popups for Settings and Help;
/// admins also get the operations console.
class SettingsMenuButton extends ConsumerWidget {
  const SettingsMenuButton({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final isAdmin = ref.watch(isAdminProvider).valueOrNull ?? false;

    return PopupMenuButton<_MenuItem>(
      icon: const Icon(Icons.menu, color: AppTheme.textSecondary),
      tooltip: 'Menu',
      color: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppTheme.cardBorder),
      ),
      onSelected: (item) {
        switch (item) {
          case _MenuItem.settings:
            showSettingsOverlay(context);
          case _MenuItem.help:
            showHelpOverlay(context);
          case _MenuItem.admin:
            context.push('/admin');
        }
      },
      itemBuilder: (_) => [
        _menuItem(_MenuItem.settings, Icons.settings_outlined, 'Settings'),
        _menuItem(_MenuItem.help, Icons.help_outline, 'Help'),
        if (isAdmin)
          _menuItem(
              _MenuItem.admin, Icons.admin_panel_settings_outlined, 'Admin console'),
      ],
    );
  }

  PopupMenuItem<_MenuItem> _menuItem(_MenuItem value, IconData icon, String label) {
    return PopupMenuItem(
      value: value,
      child: Row(
        children: [
          Icon(icon, size: 18, color: AppTheme.textSecondary),
          const SizedBox(width: 12),
          Text(label, style: const TextStyle(color: AppTheme.textPrimary, fontSize: 14)),
        ],
      ),
    );
  }
}

enum _MenuItem { settings, help, admin }
