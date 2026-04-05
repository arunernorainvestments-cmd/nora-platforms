import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';

class MarketsScreen extends StatelessWidget {
  const MarketsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Markets')),
      body: const Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.bar_chart, size: 64, color: AppTheme.textSecondary),
          SizedBox(height: 16),
          Text('Prediction Markets',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold,
                color: AppTheme.textPrimary)),
          SizedBox(height: 8),
          Text('Coming in Phase 5',
            style: TextStyle(color: AppTheme.textSecondary)),
        ]),
      ),
    );
  }
}