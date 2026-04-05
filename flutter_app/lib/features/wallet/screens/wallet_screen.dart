import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';

class WalletScreen extends StatelessWidget {
  const WalletScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Wallet')),
      body: const Center(
        child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(Icons.account_balance_wallet, size: 64, color: AppTheme.textSecondary),
          SizedBox(height: 16),
          Text('Wallet & Deposits',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold,
                color: AppTheme.textPrimary)),
          SizedBox(height: 8),
          Text('Stripe integration coming in Phase 4',
            style: TextStyle(color: AppTheme.textSecondary)),
        ]),
      ),
    );
  }
}