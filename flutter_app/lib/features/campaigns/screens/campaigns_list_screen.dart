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
        title: const Text('Campaigns Archive'),
      ),
      body: Column(
        children: [
          const _DeprecationBanner(),
          Expanded(
            child: campaigns.when(
              loading: () => const Center(child: CircularProgressIndicator()),
              error: (e, _) => const Center(
                child: Text('Failed to load campaigns archive',
                    style: TextStyle(color: AppTheme.textSecondary)),
              ),
              data: (list) {
                if (list.isEmpty) {
                  return const Center(
                    child: Padding(
                      padding: EdgeInsets.symmetric(horizontal: 32),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.inventory_2_outlined,
                              size: 48, color: AppTheme.textSecondary),
                          SizedBox(height: 16),
                          Text(
                            'No archived campaigns to display.',
                            textAlign: TextAlign.center,
                            style: TextStyle(color: AppTheme.textSecondary),
                          ),
                        ],
                      ),
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
          ),
        ],
      ),
    );
  }
}

class _DeprecationBanner extends StatelessWidget {
  const _DeprecationBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: AppTheme.surface,
      child: const Row(
        children: [
          Icon(Icons.archive_outlined,
              size: 20, color: AppTheme.textSecondary),
          SizedBox(width: 12),
          Expanded(
            child: Text(
              'Campaigns has been replaced by Likeness Cards. '
              'Your campaign history is preserved here.',
              style: TextStyle(
                color: AppTheme.textSecondary,
                fontSize: 13,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
