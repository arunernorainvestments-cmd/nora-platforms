import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/providers/theme_mode_provider.dart';

void showSettingsOverlay(BuildContext context) {
  showModalBottomSheet(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => const _SettingsSheet(),
  );
}

class _SettingsSheet extends ConsumerStatefulWidget {
  const _SettingsSheet();

  @override
  ConsumerState<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends ConsumerState<_SettingsSheet>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  static const _tabs = [
    Tab(text: 'Appearance'),
    Tab(text: 'Security'),
  ];

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: _tabs.length, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return DraggableScrollableSheet(
      initialChildSize: 0.75,
      minChildSize: 0.4,
      maxChildSize: 0.95,
      builder: (context, scrollController) => Container(
        decoration: const BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
        ),
        child: Column(
          children: [
            // Drag handle
            const SizedBox(height: 12),
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
            const SizedBox(height: 16),

            // Title
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 20),
              child: Row(
                children: [
                  Icon(Icons.settings_outlined, color: AppTheme.primary, size: 20),
                  SizedBox(width: 10),
                  Text(
                    'Settings',
                    style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // Tab bar
            Container(
              margin: const EdgeInsets.symmetric(horizontal: 20),
              decoration: BoxDecoration(
                color: AppTheme.background,
                borderRadius: BorderRadius.circular(10),
              ),
              child: TabBar(
                controller: _tabController,
                indicator: BoxDecoration(
                  color: AppTheme.primary,
                  borderRadius: BorderRadius.circular(8),
                ),
                indicatorSize: TabBarIndicatorSize.tab,
                dividerColor: Colors.transparent,
                labelColor: Colors.white,
                unselectedLabelColor: AppTheme.textSecondary,
                labelStyle: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                unselectedLabelStyle: const TextStyle(fontSize: 13),
                tabs: _tabs,
              ),
            ),
            const SizedBox(height: 4),

            // Tab content
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [
                  _AppearanceTab(scrollController: scrollController),
                  _SecurityTab(scrollController: scrollController),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Appearance Tab ──────────────────────────────────────────────────────────

class _AppearanceTab extends ConsumerWidget {
  final ScrollController scrollController;
  const _AppearanceTab({required this.scrollController});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeMode = ref.watch(themeModeProvider);

    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        const _SectionLabel('Theme'),
        const SizedBox(height: 12),
        _ThemeOptionTile(
          icon: Icons.dark_mode_outlined,
          label: 'Dark Mode',
          description: 'Easy on the eyes for late-night sessions',
          selected: themeMode == ThemeMode.dark,
          onTap: () => ref.read(themeModeProvider.notifier).state = ThemeMode.dark,
        ),
        const SizedBox(height: 8),
        _ThemeOptionTile(
          icon: Icons.light_mode_outlined,
          label: 'Light Mode',
          description: 'Bright and clean for daytime use',
          selected: themeMode == ThemeMode.light,
          onTap: () => ref.read(themeModeProvider.notifier).state = ThemeMode.light,
        ),
        const SizedBox(height: 8),
        _ThemeOptionTile(
          icon: Icons.brightness_auto_outlined,
          label: 'System Default',
          description: 'Follows your device\'s system appearance',
          selected: themeMode == ThemeMode.system,
          onTap: () => ref.read(themeModeProvider.notifier).state = ThemeMode.system,
        ),
      ],
    );
  }
}

class _ThemeOptionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final String description;
  final bool selected;
  final VoidCallback onTap;

  const _ThemeOptionTile({
    required this.icon,
    required this.label,
    required this.description,
    required this.selected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: selected ? AppTheme.primary.withValues(alpha: 0.1) : AppTheme.background,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? AppTheme.primary : AppTheme.cardBorder,
            width: selected ? 1.5 : 1,
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: selected ? AppTheme.primary : AppTheme.textSecondary, size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(
                      color: selected ? AppTheme.textPrimary : AppTheme.textSecondary,
                      fontSize: 14,
                      fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    description,
                    style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (selected)
              const Icon(Icons.check_circle, color: AppTheme.primary, size: 20),
          ],
        ),
      ),
    );
  }
}

// ─── Security Tab ─────────────────────────────────────────────────────────────

class _SecurityTab extends StatelessWidget {
  final ScrollController scrollController;
  const _SecurityTab({required this.scrollController});

  @override
  Widget build(BuildContext context) {
    return ListView(
      controller: scrollController,
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
      children: [
        const _SectionLabel('Authentication'),
        const SizedBox(height: 12),
        const _SecurityItem(
          icon: Icons.security_outlined,
          label: 'Two-Factor Authentication',
          description: 'Add an extra layer of security to your account',
          badge: '2FA',
          badgeColor: AppTheme.primary,
          trailing: _ComingSoonChip(),
          onTap: null,
        ),
        const SizedBox(height: 24),

        const _SectionLabel('Identity & Compliance'),
        const SizedBox(height: 12),
        _SecurityItem(
          icon: Icons.verified_user_outlined,
          label: 'Know Your Customer (KYC)',
          description:
              'Verify your identity to unlock Market Maker status and real-money match features',
          onTap: () {
            // Capture the router before popping — the sheet context is gone
            // after pop and can't be used for navigation.
            final router = GoRouter.of(context);
            Navigator.of(context).pop();
            router.push('/verify-identity');
          },
        ),
        const SizedBox(height: 8),
        const _SecurityItem(
          icon: Icons.account_balance_outlined,
          label: 'Bank Account',
          description: 'Connect your bank for future withdrawals',
          trailing: _ComingSoonChip(),
          onTap: null,
        ),
        const SizedBox(height: 24),

        const _SectionLabel('Tax & Legal'),
        const SizedBox(height: 12),
        const _SecurityItem(
          icon: Icons.description_outlined,
          label: 'Tax Forms',
          description: 'Access and download your annual tax documents',
          trailing: _ComingSoonChip(),
          onTap: null,
        ),
        const SizedBox(height: 24),

        const _SectionLabel('Data'),
        const SizedBox(height: 12),
        const _SecurityItem(
          icon: Icons.tune_outlined,
          label: 'My Data Preferences',
          description: 'Manage how your data is used on the platform',
          trailing: _ComingSoonChip(),
          onTap: null,
        ),
      ],
    );
  }
}

class _SecurityItem extends StatelessWidget {
  final IconData icon;
  final String label;
  final String description;
  final String? badge;
  final Color? badgeColor;
  final Widget? trailing;
  final VoidCallback? onTap;

  const _SecurityItem({
    required this.icon,
    required this.label,
    required this.description,
    this.badge,
    this.badgeColor,
    this.trailing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
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
                color: AppTheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(icon, color: AppTheme.primary, size: 20),
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
            if (trailing != null) ...[
              const SizedBox(width: 8),
              trailing!,
            ] else if (onTap != null)
              const Icon(Icons.chevron_right, color: AppTheme.textSecondary, size: 18),
          ],
        ),
      ),
    );
  }
}

class _ComingSoonChip extends StatelessWidget {
  const _ComingSoonChip();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppTheme.secondary.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppTheme.secondary.withValues(alpha: 0.3)),
      ),
      child: const Text(
        'Soon',
        style: TextStyle(color: AppTheme.secondary, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

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
