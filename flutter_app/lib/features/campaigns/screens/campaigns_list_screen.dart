import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/campaigns_providers.dart';
import '../widgets/campaign_card.dart';

class CampaignsListScreen extends ConsumerWidget {
  const CampaignsListScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final campaigns = ref.watch(campaignsListProvider);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: const Text('Campaigns'),
        actions: [
          TextButton.icon(
            onPressed: () => context.push('/campaigns/new'),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Launch'),
          ),
        ],
      ),
      body: campaigns.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => const Center(
          child: Text('Failed to load campaigns',
              style: TextStyle(color: AppTheme.textSecondary)),
        ),
        data: (list) {
          if (list.isEmpty) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.campaign_outlined,
                      size: 48, color: AppTheme.textSecondary),
                  const SizedBox(height: 16),
                  const Text('No active campaigns yet',
                      style: TextStyle(color: AppTheme.textSecondary)),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: () => context.push('/campaigns/new'),
                    child: const Text('Be the first to launch one'),
                  ),
                ],
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () => ref.refresh(campaignsListProvider.future),
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: list.length,
              itemBuilder: (context, i) => CampaignCard(
                campaign: list[i],
                onTap: () => context.push('/campaign/${list[i].id}'),
              ),
            ),
          );
        },
      ),
    );
  }
}
