import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../auth/providers/auth_provider.dart';

class HomeScreen extends ConsumerWidget {
  const HomeScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('N.O.R.A. Platforms'),
        actions: [
          IconButton(icon: const Icon(Icons.notifications_outlined), onPressed: () {}),
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                gradient: const LinearGradient(
                  colors: [AppTheme.primary, Color(0xFF9C27B0)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(16),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Welcome back,',
                    style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 14)),
                  const SizedBox(height: 4),
                  Text(user?.email?.split('@')[0] ?? 'Trader',
                    style: const TextStyle(color: Colors.white,
                        fontSize: 22, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 16),
                  Row(children: [
                    _StatChip(label: 'Balance', value: r'$0.00'),
                    const SizedBox(width: 12),
                    const _StatChip(label: 'Active Bets', value: '0'),
                  ]),
                ],
              ),
            ),
            const SizedBox(height: 24),
            const Text('Trending Markets',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary)),
            const SizedBox(height: 12),
            ...List.generate(3, (i) => _PlaceholderMarketCard(index: i)),
            const SizedBox(height: 24),
            const Text('Top Creators',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold,
                  color: AppTheme.textPrimary)),
            const SizedBox(height: 12),
            ...List.generate(3, (i) => _PlaceholderCreatorCard(index: i)),
          ],
        ),
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  const _StatChip({required this.label, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withOpacity(0.2),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(children: [
        Text(label, style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 11)),
        Text(value, style: const TextStyle(color: Colors.white,
            fontWeight: FontWeight.bold, fontSize: 16)),
      ]),
    );
  }
}

class _PlaceholderMarketCard extends StatelessWidget {
  final int index;
  const _PlaceholderMarketCard({required this.index});

  @override
  Widget build(BuildContext context) {
    final creators = ['@MrBeast', '@PewDiePie', '@Ninja'];
    final scores = ['87', '72', '91'];
    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(children: [
          CircleAvatar(
            backgroundColor: AppTheme.primary,
            child: Text(creators[index][1].toUpperCase(),
                style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold))),
          const SizedBox(width: 12),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Will \${creators[index]} grow 5% this week?',
                style: const TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('Popularity Score: \${scores[index]}',
                style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
          ])),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
            decoration: BoxDecoration(
              color: Color(0xFF00C896).withOpacity(0.2),
              borderRadius: BorderRadius.circular(6)),
            child: const Text('YES',
                style: TextStyle(color: AppTheme.success,
                    fontWeight: FontWeight.bold, fontSize: 12))),
        ]),
      ),
    );
  }
}

class _PlaceholderCreatorCard extends StatelessWidget {
  final int index;
  const _PlaceholderCreatorCard({required this.index});

  @override
  Widget build(BuildContext context) {
    final creators = ['MrBeast', 'PewDiePie', 'Ninja'];
    final platforms = ['YouTube • TikTok', 'YouTube • X', 'Kick • Twitch'];
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppTheme.surfaceLight,
          child: Text(creators[index][0],
              style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold))),
        title: Text(creators[index],
            style: const TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
        subtitle: Text(platforms[index],
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
        trailing: const Icon(Icons.arrow_forward_ios, color: AppTheme.textSecondary, size: 14),
      ),
    );
  }
}