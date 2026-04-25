import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';

// TODO: wire to trending content API

class HotTopicScreen extends StatelessWidget {
  const HotTopicScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('Hot Topic'),
        backgroundColor: AppTheme.surface,
      ),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 80,
              height: 80,
              decoration: BoxDecoration(
                color: AppTheme.danger.withValues(alpha: 0.12),
                shape: BoxShape.circle,
                border: Border.all(
                    color: AppTheme.danger.withValues(alpha: 0.35), width: 2),
              ),
              child: const Center(
                child: Icon(Icons.local_fire_department_outlined,
                    color: AppTheme.danger, size: 40),
              ),
            ),
            const SizedBox(height: 24),
            const Text(
              'Hot Topic',
              style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w800,
              ),
            ),
            const SizedBox(height: 10),
            const Text(
              'Trending content coming soon',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
