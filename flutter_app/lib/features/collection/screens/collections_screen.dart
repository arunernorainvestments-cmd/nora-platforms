import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/n_back_button.dart';
import '../../auth/providers/auth_provider.dart';
import '../../markets/providers/card_market_providers.dart';
import '../providers/collections_providers.dart';

/// `/collections` — the Market Maker's collection workshop (Collections spec
/// N2/N4). List your collections, create a new one (KYC + linked social gated),
/// add member cards through the real mint pipeline, set per-card supply + a
/// collection price, and publish.
///
/// G-COLL language ban: collections are collectible game assets. Nothing here
/// frames them as investments — no appreciation/return/yield/value-tracking copy.
class CollectionsScreen extends ConsumerWidget {
  const CollectionsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final status = ref.watch(collectionMinterStatusProvider);
    final collections = ref.watch(myCollectionsProvider);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: const NBackButton(fallback: '/collection'),
        backgroundColor: AppTheme.background,
        title: const Text('My Collections'),
      ),
      floatingActionButton: status.maybeWhen(
        data: (s) => s.eligible
            ? FloatingActionButton.extended(
                backgroundColor: AppTheme.primary,
                onPressed: () => _createDialog(context, ref),
                icon: const Icon(Icons.add),
                label: const Text('New collection'),
              )
            : null,
        orElse: () => null,
      ),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(collectionMinterStatusProvider);
          ref.invalidate(myCollectionsProvider);
          await ref.read(myCollectionsProvider.future);
        },
        child: status.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => _pad(Text('Could not load: $e',
              style: const TextStyle(color: AppTheme.danger))),
          data: (s) => ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (!s.eligible) _EligibilityCard(status: s),
              const SizedBox(height: 8),
              collections.when(
                loading: () =>
                    const Center(child: CircularProgressIndicator()),
                error: (e, _) => Text('Could not load collections: $e',
                    style: const TextStyle(color: AppTheme.danger)),
                data: (list) => list.isEmpty
                    ? _empty(s.eligible)
                    : Column(
                        children: [
                          for (final c in list)
                            _CollectionTile(collection: c),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _pad(Widget child) => Padding(
      padding: const EdgeInsets.all(24), child: Center(child: child));

  Widget _empty(bool eligible) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 48, horizontal: 16),
        child: Column(children: [
          const Icon(Icons.collections_bookmark_outlined,
              size: 48, color: AppTheme.textSecondary),
          const SizedBox(height: 12),
          const Text('No collections yet',
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.w700)),
          const SizedBox(height: 6),
          Text(
            eligible
                ? 'Create a themed series of your own posts — each becomes a '
                    'serialized, collectible card.'
                : 'Verify your identity and link a social profile to mint '
                    'collections.',
            textAlign: TextAlign.center,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
        ]),
      );

  Future<void> _createDialog(BuildContext context, WidgetRef ref) async {
    final titleCtl = TextEditingController();
    final descCtl = TextEditingController();
    final created = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('New collection',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Column(mainAxisSize: MainAxisSize.min, children: [
          TextField(
            controller: titleCtl,
            maxLength: 80,
            style: const TextStyle(color: AppTheme.textPrimary),
            decoration: const InputDecoration(labelText: 'Title'),
          ),
          TextField(
            controller: descCtl,
            maxLines: 2,
            style: const TextStyle(color: AppTheme.textPrimary),
            decoration: const InputDecoration(labelText: 'Description (optional)'),
          ),
        ]),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () async {
              if (titleCtl.text.trim().isEmpty) return;
              try {
                await CollectionService.create(titleCtl.text.trim(),
                    description: descCtl.text.trim().isEmpty
                        ? null
                        : descCtl.text.trim());
                if (ctx.mounted) Navigator.pop(ctx, true);
              } catch (e) {
                if (ctx.mounted) {
                  ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                      content: Text(CollectionService.errorMessage(e)),
                      backgroundColor: AppTheme.danger));
                }
              }
            },
            child: const Text('Create'),
          ),
        ],
      ),
    );
    if (created == true) ref.invalidate(myCollectionsProvider);
  }
}

class _EligibilityCard extends StatelessWidget {
  const _EligibilityCard({required this.status});
  final CollectionMinterStatus status;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const Text('Become a collection minter',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 10),
        _req('Identity verified (KYC)', status.kycVerified),
        _req('A social profile linked', status.linkedSocial),
        const SizedBox(height: 10),
        Row(children: [
          if (!status.kycVerified)
            TextButton(
              onPressed: () => context.go('/verify-identity'),
              child: const Text('Verify identity'),
            ),
          if (!status.linkedSocial)
            TextButton(
              onPressed: () => context.go('/profile'),
              child: const Text('Link a social'),
            ),
        ]),
      ]),
    );
  }

  Widget _req(String label, bool done) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Icon(done ? Icons.check_circle : Icons.radio_button_unchecked,
              size: 18,
              color: done ? AppTheme.success : AppTheme.textSecondary),
          const SizedBox(width: 8),
          Text(label,
              style: const TextStyle(
                  color: AppTheme.textPrimary, fontSize: 13)),
        ]),
      );
}

class _CollectionTile extends StatelessWidget {
  const _CollectionTile({required this.collection});
  final Collection collection;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => context.go('/collections/${collection.id}'),
      child: Container(
        margin: const EdgeInsets.only(bottom: 12),
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Row(children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(collection.title,
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                Text(
                  '${collection.members.length} card'
                  '${collection.members.length == 1 ? '' : 's'}'
                  '${collection.priceCents != null ? ' · \$${(collection.priceCents! / 100).toStringAsFixed(2)}' : ''}',
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
          _statusPill(collection.status),
        ]),
      ),
    );
  }

  Widget _statusPill(String status) {
    final (label, color) = switch (status) {
      'listed' => ('Listed', AppTheme.success),
      'sold_out' => ('Sold out', AppTheme.secondary),
      'minting' => ('Draft', AppTheme.primary),
      'closed' => ('Closed', AppTheme.textSecondary),
      _ => ('Draft', AppTheme.primary),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(label,
          style: TextStyle(
              color: color, fontSize: 11, fontWeight: FontWeight.w700)),
    );
  }
}

/// `/collections/:id` — the collection editor: member cards, add-a-card (routes
/// into the mint wizard tethered to this collection), and the publish flow
/// (per-card supply + price → mint fee charged → serialized copies generated).
class CollectionEditorScreen extends ConsumerWidget {
  const CollectionEditorScreen({super.key, required this.collectionId});
  final String collectionId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final coll = ref.watch(collectionProvider(collectionId));
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: const NBackButton(fallback: '/collections'),
        backgroundColor: AppTheme.background,
        title: const Text('Collection'),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(collectionProvider(collectionId).future),
        child: coll.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(
              child: Text('Could not load: $e',
                  style: const TextStyle(color: AppTheme.danger))),
          data: (c) => c == null
              ? const Center(
                  child: Text('Collection not found',
                      style: TextStyle(color: AppTheme.textSecondary)))
              : _body(context, ref, c),
        ),
      ),
    );
  }

  Widget _body(BuildContext context, WidgetRef ref, Collection c) {
    final myId = ref.watch(currentUserProvider)?.id;
    final isOwner = myId != null && myId == c.marketMakerUserId;
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(c.title,
          style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w800)),
      if (c.description != null && c.description!.trim().isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(c.description!,
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
      ],
      const SizedBox(height: 20),
      Row(children: [
        const Text('Cards',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700)),
        const Spacer(),
        if (c.isDraft && isOwner)
          TextButton.icon(
            onPressed: () => context.go('/mint?collection=${c.id}'),
            icon: const Icon(Icons.add, size: 18),
            label: const Text('Add a card'),
          ),
      ]),
      const SizedBox(height: 8),
      if (c.members.isEmpty)
        const Padding(
          padding: EdgeInsets.symmetric(vertical: 24),
          child: Text(
            'No cards yet. Add cards from your own posts — each runs the full '
            'mint pipeline.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
          ),
        )
      else
        for (final m in c.members) _memberRow(m, c.isListed),
      const SizedBox(height: 24),
      if (c.isDraft && isOwner)
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
          onPressed: c.members.isEmpty || c.members.any((m) => !m.finalized)
              ? null
              : () => _publishDialog(context, ref, c),
          icon: const Icon(Icons.rocket_launch_outlined),
          label: const Text('Set supply & price, publish'),
        )
      else if (c.isListed && isOwner)
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.success.withValues(alpha: 0.4)),
          ),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
              'Listed for ${c.priceLabel} — buyers receive one serialized copy '
              'of each card.',
              style: const TextStyle(color: AppTheme.textPrimary, fontSize: 13),
            ),
            const SizedBox(height: 8),
            TextButton.icon(
              onPressed: () => _selloutMarketDialog(context, c),
              icon: const Icon(Icons.insights_outlined, size: 18),
              label: const Text('Open a sell-out prediction market'),
            ),
          ]),
        )
      else if (c.isListed && !isOwner)
        Column(children: [
          _BuyCollectionButton(collection: c),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: () => _selloutMarketDialog(context, c),
            icon: const Icon(Icons.insights_outlined, size: 18),
            label: const Text('Predict when it sells out'),
          ),
        ])
      else if (c.isSoldOut)
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: AppTheme.cardBorder),
          ),
          child: const Text('This collection is sold out.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
        ),
    ]);
  }

  Widget _memberRow(CollectionMember m, bool listed) => Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppTheme.surfaceLight,
              borderRadius: BorderRadius.circular(8),
              image: m.cardArtUrl != null
                  ? DecorationImage(
                      image: NetworkImage(m.cardArtUrl!), fit: BoxFit.cover)
                  : null,
            ),
            child: m.cardArtUrl == null
                ? const Icon(Icons.auto_awesome,
                    size: 18, color: AppTheme.textSecondary)
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(m.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                Text(
                  '${m.tier}-tier'
                  '${listed ? ' · ${m.totalSupply} copies' : ''}'
                  '${m.finalized ? '' : ' · finalizing…'}',
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 11),
                ),
              ],
            ),
          ),
        ]),
      );

  Future<void> _publishDialog(
      BuildContext context, WidgetRef ref, Collection c) async {
    final priceCtl = TextEditingController();
    final supplyCtls = {
      for (final m in c.members) m.chitId: TextEditingController(text: '100'),
    };
    final published = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: const Text('Publish collection',
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 17)),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Align(
                alignment: Alignment.centerLeft,
                child: Text('Copies per card (1–1000, fixed once published)',
                    style:
                        TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
              ),
              const SizedBox(height: 8),
              for (final m in c.members)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Row(children: [
                    Expanded(
                      child: Text(m.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                              color: AppTheme.textPrimary, fontSize: 13)),
                    ),
                    SizedBox(
                      width: 90,
                      child: TextField(
                        controller: supplyCtls[m.chitId],
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly
                        ],
                        style: const TextStyle(color: AppTheme.textPrimary),
                        decoration: const InputDecoration(isDense: true),
                      ),
                    ),
                  ]),
                ),
              const Divider(color: AppTheme.cardBorder),
              TextField(
                controller: priceCtl,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.allow(RegExp(r'[0-9.]'))
                ],
                style: const TextStyle(color: AppTheme.textPrimary),
                decoration: const InputDecoration(
                    labelText: 'Collection price (USD)', prefixText: '\$'),
              ),
            ]),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
              onPressed: () async {
                final priceCents =
                    ((double.tryParse(priceCtl.text.trim()) ?? 0) * 100)
                        .round();
                if (priceCents <= 0) return;
                final supplies = <String, int>{};
                for (final e in supplyCtls.entries) {
                  final v = int.tryParse(e.value.text.trim()) ?? 0;
                  if (v < 1 || v > 1000) return;
                  supplies[e.key] = v;
                }
                try {
                  await CollectionService.publish(c.id,
                      priceCents: priceCents, supplies: supplies);
                  if (ctx.mounted) Navigator.pop(ctx, true);
                } catch (err) {
                  if (ctx.mounted) {
                    ScaffoldMessenger.of(ctx).showSnackBar(SnackBar(
                        content: Text(CollectionService.errorMessage(err)),
                        backgroundColor: AppTheme.danger));
                  }
                }
              },
              child: const Text('Publish'),
            ),
          ],
        ),
      ),
    );
    if (published == true) {
      ref.invalidate(collectionProvider(collectionId));
      ref.invalidate(myCollectionsProvider);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Collection published.'),
            backgroundColor: AppTheme.surface));
      }
    }
  }

  /// Opens a token sell-out prediction market on this collection (N5). Deadline
  /// picked in whole days; resolves automatically from the sold-out transition.
  Future<void> _selloutMarketDialog(
      BuildContext context, Collection c) async {
    var days = 30;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: const Text('Sell-out market',
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 17)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('"Will ${c.title} sell out within $days days?" — token bets.',
                style:
                    const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
            Slider(
              value: days.toDouble(),
              min: 1,
              max: 90,
              divisions: 89,
              label: '$days days',
              onChanged: (v) => setState(() => days = v.round()),
            ),
          ]),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx, false),
                child: const Text('Cancel')),
            FilledButton(
                onPressed: () => Navigator.pop(ctx, true),
                child: const Text('Open market')),
          ],
        ),
      ),
    );
    if (ok != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await CardMarketService.createSelloutMarket(
          collectionId: c.id,
          endAt: DateTime.now().add(Duration(days: days)));
      messenger.showSnackBar(const SnackBar(
          content: Text('Market opened — find it under Card Markets.'),
          backgroundColor: AppTheme.surface));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(CardMarketService.errorMessage(e)),
          backgroundColor: AppTheme.danger));
    }
  }
}

/// Buy-collection CTA with its own busy state + a stable idempotency key so a
/// double-tap (or a retry after a flaky network) never double-charges — the
/// key is generated once and reused across retries (server is idempotent too).
class _BuyCollectionButton extends ConsumerStatefulWidget {
  const _BuyCollectionButton({required this.collection});
  final Collection collection;

  @override
  ConsumerState<_BuyCollectionButton> createState() =>
      _BuyCollectionButtonState();
}

class _BuyCollectionButtonState extends ConsumerState<_BuyCollectionButton> {
  bool _busy = false;
  late final String _idemKey = CollectionService.newIdempotencyKey();

  @override
  Widget build(BuildContext context) {
    final c = widget.collection;
    return Column(children: [
      Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Row(children: [
          Expanded(
            child: Text(
              '${c.members.length} serialized card'
              '${c.members.length == 1 ? '' : 's'} — one copy of each, playable '
              'in Arena.',
              style:
                  const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
            ),
          ),
          Text(c.priceLabel,
              style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.w800)),
        ]),
      ),
      const SizedBox(height: 12),
      SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
          onPressed: _busy ? null : _buy,
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.shopping_cart_checkout),
          label: Text('Buy collection · ${c.priceLabel}'),
        ),
      ),
    ]);
  }

  Future<void> _buy() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await CollectionService.buyCollection(widget.collection.id,
          idempotencyKey: _idemKey);
      if (!mounted) return;
      messenger.showSnackBar(const SnackBar(
          content:
              Text('Collection purchased — the cards are in your collection.'),
          backgroundColor: AppTheme.surface));
      ref.invalidate(collectionProvider(widget.collection.id));
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(
          content: Text(CollectionService.errorMessage(e)),
          backgroundColor: AppTheme.danger));
    }
  }
}

/// `/market/collections` — browse publicly listed collections and open one to
/// buy. G-COLL: collectible game assets only; no value/appreciation framing.
class CollectionsBrowseScreen extends ConsumerWidget {
  const CollectionsBrowseScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listed = ref.watch(listedCollectionsProvider);
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: const NBackButton(fallback: '/market'),
        backgroundColor: AppTheme.background,
        title: const Text('Collections'),
      ),
      body: RefreshIndicator(
        onRefresh: () => ref.refresh(listedCollectionsProvider.future),
        child: listed.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => Center(
              child: Text('Could not load: $e',
                  style: const TextStyle(color: AppTheme.danger))),
          data: (list) => list.isEmpty
              ? ListView(children: const [
                  SizedBox(height: 120),
                  Icon(Icons.collections_bookmark_outlined,
                      size: 48, color: AppTheme.textSecondary),
                  SizedBox(height: 12),
                  Center(
                    child: Text('No collections listed yet',
                        style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.w700)),
                  ),
                ])
              : ListView(
                  padding: const EdgeInsets.all(16),
                  children: [for (final c in list) _tile(context, c)],
                ),
        ),
      ),
    );
  }

  Widget _tile(BuildContext context, Collection c) => GestureDetector(
        onTap: () => context.go('/collections/${c.id}'),
        child: Container(
          margin: const EdgeInsets.only(bottom: 12),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AppTheme.cardBorder),
          ),
          child: Row(children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(c.title,
                      style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                    '${c.members.length} card'
                    '${c.members.length == 1 ? '' : 's'}'
                    '${c.isSoldOut ? ' · sold out' : ''}',
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 12),
                  ),
                ],
              ),
            ),
            Text(c.priceLabel,
                style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 16,
                    fontWeight: FontWeight.w800)),
          ]),
        ),
      );
}
