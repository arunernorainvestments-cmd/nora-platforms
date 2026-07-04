import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../theme/app_theme.dart';

/// The one canonical "Create Your BattleChit" entry point. Every surface that
/// mentions BattleChits links to the same /mint workflow through these two
/// widgets so the flow is discoverable everywhere (home, profile, battle,
/// marketplace, FAQ...). Unauthenticated users are bounced through /login by
/// the router redirect and land back on /mint.
class BattleChitBanner extends StatelessWidget {
  /// Compact drops the description line — for sidebars/tight sections.
  final bool compact;
  const BattleChitBanner({super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.go('/mint'),
      child: Container(
        padding: EdgeInsets.all(compact ? 14 : 20),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          gradient: const LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF241866), Color(0xFF0D2A3E)],
          ),
          border: Border.all(color: AppTheme.secondary, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: AppTheme.secondary.withValues(alpha: 0.25),
              blurRadius: 18,
              spreadRadius: 1,
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: AppTheme.secondary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                      color: AppTheme.secondary.withValues(alpha: 0.5)),
                ),
                child: const Icon(Icons.auto_awesome,
                    color: AppTheme.secondary, size: 20),
              ),
              const SizedBox(width: 12),
              const Expanded(
                child: Text(
                  'Create Your BattleChit',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.secondary,
                  borderRadius: BorderRadius.circular(20),
                ),
                child: const Text(
                  'NEW',
                  style: TextStyle(
                    color: Colors.black87,
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1,
                  ),
                ),
              ),
            ]),
            if (!compact) ...[
              const SizedBox(height: 10),
              const Text(
                'Turn a viral post you own into a playable card with its own '
                'anime cutscene — then battle with it in the NORA Arena app.',
                style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
            ],
            const SizedBox(height: 14),
            const BattleChitButton(),
          ],
        ),
      ),
    );
  }
}

/// The inline full-width button variant — drop next to any BattleChit mention.
class BattleChitButton extends StatelessWidget {
  final String label;
  const BattleChitButton({super.key, this.label = 'Create Your BattleChit →'});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.go('/mint'),
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(vertical: 12),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [AppTheme.primary, Color(0xFF03A9BE)],
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          label,
          textAlign: TextAlign.center,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 14,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
