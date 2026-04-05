import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';

class DiscoverScreen extends StatelessWidget {
  const DiscoverScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Discover Creators')),
      body: const Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.explore, size: 64, color: AppTheme.textSecondary),
          SizedBox(height: 16),
          Text('Creator Discovery',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold,
                color: AppTheme.textPrimary)),
          SizedBox(height: 8),
          Text('Coming in Phase 3',
            style: TextStyle(color: AppTheme.textSecondary)),
        ]),
      ),
    );
  }
}