import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/card_face.dart';
import '../providers/collection_providers.dart';

/// "My BattleChits" — the minted moment chits the user owns. This is where a
/// freshly minted card lands after the mint wizard finalizes it.
class CollectionScreen extends ConsumerWidget {
  const CollectionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(myCollectionProvider);
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.background,
        title: const Text('My BattleChits'),
        actions: [
          IconButton(
            tooltip: 'Mint a new one',
            icon: const Icon(Icons.add),
            onPressed: () => context.go('/mint'),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () async => ref.refresh(myCollectionProvider.future),
        child: async.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => _CenteredMessage(
            icon: Icons.error_outline,
            title: 'Could not load your collection',
            detail: '$e',
          ),
          data: (chits) => chits.isEmpty
              ? _EmptyState(onMint: () => context.go('/mint'))
              : _grid(context, chits),
        ),
      ),
    );
  }

  Widget _grid(BuildContext context, List<CollectionChit> chits) {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      physics: const AlwaysScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        childAspectRatio: 0.62,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
      ),
      itemCount: chits.length,
      itemBuilder: (ctx, i) => _ChitCard(
        chit: chits[i],
        onTap: () => _showCard(ctx, chits[i]),
      ),
    );
  }

  void _showCard(BuildContext context, CollectionChit chit) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 360),
                child: CardFace(
                  name: chit.name,
                  chitType: chit.chitType,
                  family: chit.family,
                  tier: chit.tier,
                  auraCost: chit.auraCost,
                  atk: chit.atk,
                  hp: chit.hp,
                  keywords: chit.keywords,
                  cardArtUrl: chit.cardArtUrl,
                  minterHandle: chit.minterHandle,
                  sourcePlatform: chit.sourcePlatform,
                  rulesText: chit.rulesText,
                  flavor: chit.flavor,
                  serial: chit.serial,
                ),
              ),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Close',
                  style: TextStyle(color: AppTheme.textPrimary)),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChitCard extends StatelessWidget {
  const _ChitCard({required this.chit, this.onTap});
  final CollectionChit chit;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: chit.isPending ? AppTheme.secondary : AppTheme.cardBorder,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (chit.cardArtUrl != null)
                  Image.network(chit.cardArtUrl!,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => _artFallback())
                else
                  _artFallback(),
                Positioned(
                  top: 8,
                  right: 8,
                  child: _pill('Tier ${chit.tier}', AppTheme.primary),
                ),
                if (chit.isPending)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: _pill('Pending', AppTheme.secondary),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(chit.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(
                  '${chit.chitType == 'spell_moment' ? 'Spell' : 'Creature'}'
                  '${chit.family.isEmpty ? '' : ' · ${chit.family}'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 11),
                ),
                const SizedBox(height: 8),
                Row(children: [
                  _stat(Icons.bolt, '${chit.auraCost}', AppTheme.secondary),
                  const SizedBox(width: 10),
                  if (chit.chitType != 'spell_moment') ...[
                    _stat(Icons.local_fire_department, '${chit.atk}',
                        AppTheme.danger),
                    const SizedBox(width: 10),
                    _stat(Icons.favorite, '${chit.hp}', AppTheme.success),
                  ],
                ]),
              ],
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _artFallback() => Container(
        color: AppTheme.surfaceLight,
        child: const Center(
          child: Icon(Icons.auto_awesome, color: AppTheme.textSecondary, size: 32),
        ),
      );

  Widget _pill(String text, Color color) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.9),
          borderRadius: BorderRadius.circular(999),
        ),
        child: Text(text,
            style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w700)),
      );

  Widget _stat(IconData icon, String value, Color color) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 13, color: color),
          const SizedBox(width: 3),
          Text(value,
              style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600)),
        ],
      );
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({required this.onMint});
  final VoidCallback onMint;

  @override
  Widget build(BuildContext context) {
    return ListView(
      // ListView so RefreshIndicator still works on the empty state.
      children: [
        const SizedBox(height: 120),
        const Icon(Icons.style_outlined,
            size: 56, color: AppTheme.textSecondary),
        const SizedBox(height: 16),
        const Center(
          child: Text('No BattleChits yet',
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w700)),
        ),
        const SizedBox(height: 8),
        const Center(
          child: Text('Mint one from a moment you own to start your deck.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
        ),
        const SizedBox(height: 20),
        Center(
          child: FilledButton.icon(
            onPressed: onMint,
            icon: const Icon(Icons.add),
            label: const Text('Create a BattleChit'),
          ),
        ),
      ],
    );
  }
}

class _CenteredMessage extends StatelessWidget {
  const _CenteredMessage(
      {required this.icon, required this.title, required this.detail});
  final IconData icon;
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) {
    return ListView(children: [
      const SizedBox(height: 120),
      Icon(icon, size: 48, color: AppTheme.danger),
      const SizedBox(height: 12),
      Center(
        child: Text(title,
            style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700)),
      ),
      const SizedBox(height: 6),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Text(detail,
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
      ),
    ]);
  }
}
