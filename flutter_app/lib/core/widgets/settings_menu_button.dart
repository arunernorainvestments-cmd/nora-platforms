import 'package:flutter/material.dart';
import '../theme/app_theme.dart';
import '../../features/settings/widgets/settings_overlay.dart';
import '../../features/settings/widgets/help_overlay.dart';

/// Sandwich (hamburger) icon in the AppBar. Opens popups for Settings and Help.
class SettingsMenuButton extends StatelessWidget {
  const SettingsMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
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
        }
      },
      itemBuilder: (_) => [
        _menuItem(_MenuItem.settings, Icons.settings_outlined, 'Settings'),
        _menuItem(_MenuItem.help, Icons.help_outline, 'Help'),
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

enum _MenuItem { settings, help }
