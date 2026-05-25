import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';

void showHelpOverlay(BuildContext context) {
  showModalBottomSheet(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (_) => _HelpSheet(parentContext: context),
  );
}

class _HelpSheet extends StatelessWidget {
  final BuildContext parentContext;
  const _HelpSheet({required this.parentContext});

  void _navigate(BuildContext sheetContext, String path) {
    Navigator.of(sheetContext).pop();
    parentContext.push(path);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Drag handle
              Center(
                child: Container(
                  width: 40,
                  height: 4,
                  decoration: BoxDecoration(
                    color: AppTheme.cardBorder,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
              const SizedBox(height: 20),

              // Title
              const Row(
                children: [
                  Icon(Icons.help_outline, color: AppTheme.primary, size: 20),
                  SizedBox(width: 10),
                  Text(
                    'Help & Legal',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              const Text(
                'Resources, policies, and support',
                style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
              ),
              const SizedBox(height: 24),

              // Support section
              const _GroupLabel('Support'),
              const SizedBox(height: 10),
              _HelpTile(
                icon: Icons.support_agent_outlined,
                iconColor: AppTheme.primary,
                label: 'Contact Support',
                description: 'Submit a help ticket — we respond within 24–48 hours',
                onTap: () => _navigate(context, '/support'),
              ),
              const SizedBox(height: 8),
              _HelpTile(
                icon: Icons.quiz_outlined,
                iconColor: AppTheme.secondary,
                label: 'FAQ',
                description: 'Answers to common questions about N.O.R.A.',
                onTap: () => _navigate(context, '/faq'),
              ),
              const SizedBox(height: 20),

              // Legal section
              const _GroupLabel('Legal'),
              const SizedBox(height: 10),
              _HelpTile(
                icon: Icons.privacy_tip_outlined,
                iconColor: AppTheme.textSecondary,
                label: 'Privacy Policy',
                description: 'How we collect, use, and protect your data',
                onTap: () => _navigate(context, '/privacy'),
              ),
              const SizedBox(height: 8),
              _HelpTile(
                icon: Icons.description_outlined,
                iconColor: AppTheme.textSecondary,
                label: 'Terms of Service',
                description: 'Platform rules, eligibility, and user responsibilities',
                onTap: () => _navigate(context, '/terms'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HelpTile extends StatelessWidget {
  final IconData icon;
  final Color iconColor;
  final String label;
  final String description;
  final VoidCallback onTap;

  const _HelpTile({
    required this.icon,
    required this.iconColor,
    required this.label,
    required this.description,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.background,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: iconColor.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: iconColor, size: 20),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: const TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 3),
                  Text(
                    description,
                    style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.chevron_right, color: AppTheme.textSecondary, size: 18),
          ],
        ),
      ),
    );
  }
}

class _GroupLabel extends StatelessWidget {
  final String text;
  const _GroupLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text.toUpperCase(),
      style: const TextStyle(
        color: AppTheme.textSecondary,
        fontSize: 11,
        fontWeight: FontWeight.w600,
        letterSpacing: 1.2,
      ),
    );
  }
}
