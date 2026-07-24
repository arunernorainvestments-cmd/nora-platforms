import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/collections_providers.dart';

/// Profile "Collections" section (Collections spec N4) — the series a Market
/// Maker has created, with card + supply/sold set counts. Shown on the public
/// profile and the owner's private profile.
///
/// G-COLL language ban: counts only. No value, price, appreciation, or
/// "worth more" framing anywhere here.
///
/// N7 hook: campaign-won clips + their associated mints will render alongside
/// these (Clip Campaigns phase); the section is structured so that lands as a
/// sibling block without a rebuild.
class CollectionsProfileSection extends ConsumerWidget {
  const CollectionsProfileSection({super.key, required this.userId});
  final String userId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(userPublicCollectionsProvider(userId));
    return async.maybeWhen(
      data: (collections) {
        if (collections.isEmpty) return const SizedBox.shrink();
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Row(children: [
                Icon(Icons.collections_bookmark_outlined,
                    size: 18, color: AppTheme.secondary),
                SizedBox(width: 8),
                Text('Collections',
                    style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w800)),
              ]),
              const SizedBox(height: 10),
              for (final c in collections) _tile(context, c),
            ],
          ),
        );
      },
      orElse: () => const SizedBox.shrink(),
    );
  }

  Widget _tile(BuildContext context, PublicCollectionSummary c) => GestureDetector(
        onTap: () => context.push('/collections/${c.id}'),
        child: Container(
          margin: const EdgeInsets.only(bottom: 10),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.cardBorder),
          ),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                    '${c.cardCount} card${c.cardCount == 1 ? '' : 's'} · '
                    '${c.soldSets} of ${c.totalSets} sold',
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 12),
                  ),
                ],
              ),
            ),
            if (c.status == 'sold_out')
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: AppTheme.secondary.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(999),
                ),
                child: const Text('Sold out',
                    style: TextStyle(
                        color: AppTheme.secondary,
                        fontSize: 10,
                        fontWeight: FontWeight.w700)),
              ),
          ]),
        ),
      );
}
