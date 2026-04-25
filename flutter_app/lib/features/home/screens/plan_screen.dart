import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';

// TODO: populate with Phase 2 and Phase 3 roadmap content

class PlanScreen extends StatelessWidget {
  const PlanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('Roadmap'),
        backgroundColor: AppTheme.surface,
      ),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 88,
                height: 88,
                decoration: BoxDecoration(
                  color: AppTheme.primary.withValues(alpha: 0.10),
                  shape: BoxShape.circle,
                  border: Border.all(
                      color: AppTheme.primary.withValues(alpha: 0.35), width: 2),
                ),
                child: const Center(
                  child: Text('🚀', style: TextStyle(fontSize: 40)),
                ),
              ),
              const SizedBox(height: 28),
              const Text(
                'Phase 2 & 3 Coming Soon',
                style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 12),
              const Text(
                'The full roadmap will be published here before launch',
                style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 15,
                  height: 1.5,
                ),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}
