import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';

/// Gear icon that lives in every authenticated screen's AppBar actions.
/// Opens a popup menu with app-wide settings and legal links.
class SettingsMenuButton extends StatelessWidget {
  const SettingsMenuButton({super.key});

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<_SettingsItem>(
      icon: const Icon(Icons.settings_outlined, color: AppTheme.textSecondary),
      tooltip: 'Settings',
      color: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppTheme.cardBorder),
      ),
      onSelected: (item) {
        switch (item) {
          case _SettingsItem.privacyPolicy:
            context.push('/privacy');
        }
      },
      itemBuilder: (_) => [
        const PopupMenuItem(
          value: _SettingsItem.privacyPolicy,
          child: Row(
            children: [
              Icon(Icons.privacy_tip_outlined,
                  size: 18, color: AppTheme.textSecondary),
              SizedBox(width: 12),
              Text('Privacy Policy',
                  style: TextStyle(color: AppTheme.textPrimary, fontSize: 14)),
            ],
          ),
        ),
      ],
    );
  }
}

enum _SettingsItem { privacyPolicy }
