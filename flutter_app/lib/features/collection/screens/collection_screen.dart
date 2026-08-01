import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/card_face.dart';
import '../../../core/widgets/cutscene_video.dart';
import '../../market/providers/market_providers.dart';
import '../../markets/providers/card_market_providers.dart';
import '../../mint/services/mint_service.dart';
import '../../wallet/providers/wallet_providers.dart';
import '../providers/collection_providers.dart';
import '../services/ascension_service.dart';
import '../../../core/widgets/n_back_button.dart';

/// Toggle: group the collection by its source Collections vs a flat grid.
final _groupByCollectionProvider = StateProvider.autoDispose<bool>((_) => false);

/// "My BattleChits" — the minted moment chits the user owns. This is where a
/// freshly minted card lands after the mint wizard finalizes it. Cards can be
/// viewed flat or grouped by their source Collection (Collections spec N4).
class CollectionScreen extends ConsumerWidget {
  const CollectionScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(myCollectionProvider);
    final grouped = ref.watch(_groupByCollectionProvider);
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: const NBackButton(fallback: '/battle'),
        backgroundColor: AppTheme.background,
        title: const Text('My BattleChits'),
        actions: [
          IconButton(
            tooltip: grouped ? 'Flat view' : 'Group by collection',
            icon: Icon(grouped ? Icons.grid_view : Icons.collections_outlined),
            onPressed: () =>
                ref.read(_groupByCollectionProvider.notifier).state = !grouped,
          ),
          const _AscensionAction(),
          IconButton(
            tooltip: 'My Collections',
            icon: const Icon(Icons.collections_bookmark_outlined),
            onPressed: () => context.push('/collections'),
          ),
          IconButton(
            tooltip: 'Chit Market',
            icon: const Icon(Icons.storefront_outlined),
            onPressed: () => context.push('/market'),
          ),
          IconButton(
            tooltip: 'Mint a new one',
            icon: const Icon(Icons.add),
            onPressed: () => context.push('/mint'),
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
              ? _EmptyState(onMint: () => context.push('/mint'))
              : Column(
                  children: [
                    // The playset is the floor; the personal mint is the point.
                    // Shown until this account owns a card it minted itself.
                    if (chits.every((c) => c.isStarter))
                      _MintYourMomentBanner(
                          onMint: () => context.push('/mint'),
                          onBuildDeck: () => context.push('/decks')),
                    Expanded(
                      child: grouped
                          ? _grouped(context, chits)
                          : _grid(context, chits),
                    ),
                  ],
                ),
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

  /// Grouped view: one section per source collection, then "Singles" for cards
  /// that don't belong to a collection.
  Widget _grouped(BuildContext context, List<CollectionChit> chits) {
    final byCollection = <String, List<CollectionChit>>{};
    final singles = <CollectionChit>[];
    final titles = <String, String>{};
    for (final c in chits) {
      if (c.collectionId != null) {
        (byCollection[c.collectionId!] ??= []).add(c);
        titles[c.collectionId!] = c.collectionTitle ?? 'Collection';
      } else {
        singles.add(c);
      }
    }
    final sections = [
      ...byCollection.entries
          .map((e) => (title: titles[e.key]!, chits: e.value)),
      if (singles.isNotEmpty) (title: 'Singles', chits: singles),
    ];
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        for (final s in sections) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 10, top: 4),
            child: Text('${s.title}  ·  ${s.chits.length}',
                style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w800)),
          ),
          GridView.builder(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 220,
              childAspectRatio: 0.62,
              crossAxisSpacing: 14,
              mainAxisSpacing: 14,
            ),
            itemCount: s.chits.length,
            itemBuilder: (ctx, i) => _ChitCard(
              chit: s.chits[i],
              onTap: () => _showCard(ctx, s.chits[i]),
            ),
          ),
          const SizedBox(height: 20),
        ],
      ],
    );
  }

  void _showCard(BuildContext context, CollectionChit chit) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
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
                  copyOf: chit.copyOfLabel,
                ),
              ),
              if (chit.isStarter) ...[
                const SizedBox(height: 8),
                Text(
                  'Standard Playset card · you own ${chit.ownedQuantity} '
                  '${chit.ownedQuantity == 1 ? 'copy' : 'copies'}. Free with every '
                  'account, playable everywhere — starters are never traded or sold.',
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12),
                ),
              ] else if (chit.ownedSerials.length > 1) ...[
                const SizedBox(height: 8),
                Text(
                  'You own ${chit.ownedSerials.length} copies · serials '
                  '${(chit.ownedSerials..sort()).map((s) => '#$s').join(', ')}',
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12),
                ),
              ],
              if (chit.cutsceneUrl != null) ...[
                const SizedBox(height: 12),
                _CutscenePreview(url: chit.cutsceneUrl!),
              ],
              const SizedBox(height: 12),
              if (chit.isPending)
                _PendingActions(chit: chit, dialogContext: ctx)
              else
                _MarketActions(chit: chit, dialogContext: ctx),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Close',
                    style: TextStyle(color: AppTheme.textPrimary)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Collapsed-by-default player for the chit's summon cutscene — the animation
/// that plays when the card is summoned in battle. Collapsed so opening a card
/// never auto-downloads video; tapping loads the MP4 (autoplays muted, controls
/// allow unmuting to hear the moment's audio).
class _CutscenePreview extends StatefulWidget {
  const _CutscenePreview({required this.url});
  final String url;

  @override
  State<_CutscenePreview> createState() => _CutscenePreviewState();
}

class _CutscenePreviewState extends State<_CutscenePreview> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 360),
      child: _open
          ? Column(mainAxisSize: MainAxisSize.min, children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: AspectRatio(
                    aspectRatio: 16 / 9,
                    child: CutsceneVideo(url: widget.url)),
              ),
              const SizedBox(height: 4),
              const Text('How this card looks when summoned in battle',
                  style:
                      TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
            ])
          : OutlinedButton.icon(
              onPressed: () => setState(() => _open = true),
              icon: const Icon(Icons.play_circle_outline, size: 18),
              label: const Text('Watch summon cutscene'),
            ),
    );
  }
}

/// Actions for a chit still stuck at the mint Preview gate (is_active = false,
/// the "Pending" pill). Happens when the tab closed or refreshed before "add to
/// my collection" — the chit is owned but never previewed/finalized. Viewing
/// the card here satisfies the preview (chit_record_preview), then finalize
/// activates it; both RPCs are owner-scoped server-side.
class _PendingActions extends ConsumerStatefulWidget {
  const _PendingActions({required this.chit, required this.dialogContext});
  final CollectionChit chit;
  final BuildContext dialogContext;

  @override
  ConsumerState<_PendingActions> createState() => _PendingActionsState();
}

class _PendingActionsState extends ConsumerState<_PendingActions> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    return Column(mainAxisSize: MainAxisSize.min, children: [
      Container(
        constraints: const BoxConstraints(maxWidth: 360),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
              color: AppTheme.secondary.withValues(alpha: 0.5)),
        ),
        child: const Text(
          'This card isn\'t finished yet — the mint stopped before the final '
          'step. Finalize it to add it to your collection, or discard it to '
          'free up your mint slot.',
          textAlign: TextAlign.center,
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
        ),
      ),
      const SizedBox(height: 10),
      FilledButton.icon(
        onPressed: _busy ? null : _finalize,
        icon: _busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.check_circle_outline),
        label: const Text('Add to my collection'),
      ),
      TextButton.icon(
        onPressed: _busy ? null : _discard,
        icon: const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger),
        label: const Text('Discard this card',
            style: TextStyle(color: AppTheme.danger)),
      ),
    ]);
  }

  Future<void> _finalize() async {
    final messenger = ScaffoldMessenger.of(widget.dialogContext);
    setState(() => _busy = true);
    try {
      await MintService.recordPreview(widget.chit.id);
      await MintService.finalizePreview(widget.chit.id);
      if (widget.dialogContext.mounted) Navigator.pop(widget.dialogContext);
      messenger.showSnackBar(SnackBar(
          content: Text('${widget.chit.name} is now in your collection.'),
          backgroundColor: AppTheme.surface));
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(
          content: Text('Could not finalize — $e'),
          backgroundColor: AppTheme.danger));
    } finally {
      ref.invalidate(myCollectionProvider);
    }
  }

  Future<void> _discard() async {
    final messenger = ScaffoldMessenger.of(widget.dialogContext);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Discard this card?',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: const Text(
          'This permanently deletes the generated card and its cutscene, and '
          'frees your self-mint slot. Your original moment stays linked, so '
          'you can mint it again. This can\'t be undone.',
          style: TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep it')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Discard')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await MintService.cancelMint(widget.chit.id);
      if (widget.dialogContext.mounted) Navigator.pop(widget.dialogContext);
      messenger.showSnackBar(SnackBar(
          content: Text('${widget.chit.name} discarded.'),
          backgroundColor: AppTheme.surface));
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(
          content: Text('Could not discard — $e'),
          backgroundColor: AppTheme.danger));
    } finally {
      ref.invalidate(myCollectionProvider);
    }
  }
}

/// Sell / Delist actions for a card in the collection dialog. Prices are the
/// fixed tier prices from `marketplace_tier_pricing` (Hard Rule 40 — config,
/// never user-set); the server re-validates everything on the RPC.
class _MarketActions extends ConsumerStatefulWidget {
  const _MarketActions({required this.chit, required this.dialogContext});
  final CollectionChit chit;
  final BuildContext dialogContext;

  @override
  ConsumerState<_MarketActions> createState() => _MarketActionsState();
}

class _MarketActionsState extends ConsumerState<_MarketActions> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final chit = widget.chit;
    if (chit.isListed) {
      return Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Listed on the Chit Market',
            style: TextStyle(color: AppTheme.secondary, fontSize: 12)),
        const SizedBox(height: 6),
        FilledButton.icon(
          style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
          onPressed: _busy ? null : _delist,
          icon: const Icon(Icons.remove_shopping_cart_outlined),
          label: const Text('Delist'),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(widget.dialogContext);
            context.go('/market');
          },
          child: const Text('View on the Market',
              style: TextStyle(color: AppTheme.secondary)),
        ),
      ]);
    }
    if (!chit.isSellable) return const SizedBox.shrink();

    final pricing = ref.watch(tierPricingProvider).valueOrNull;
    final price = pricing?[chit.tier];

    return Column(mainAxisSize: MainAxisSize.min, children: [
      if (price != null) ...[
        FilledButton.icon(
          onPressed: _busy ? null : () => _sell(price),
          icon: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2))
              : const Icon(Icons.sell_outlined),
          label: Text('Sell for ${price.tokens} tokens'),
        ),
        if (price.feeBps > 0)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              '${price.feeBps ~/ 100}% is burned on sale — you receive '
              '${price.netToSeller} tokens.',
              style:
                  const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
            ),
          ),
      ],
      TextButton.icon(
        onPressed: _busy ? null : _ascensionMarket,
        icon: const Icon(Icons.insights_outlined, size: 18),
        label: const Text('Open an ascension market'),
      ),
      TextButton.icon(
        onPressed: _busy ? null : _delete,
        icon:
            const Icon(Icons.delete_outline, size: 18, color: AppTheme.danger),
        label: const Text('Delete this card',
            style: TextStyle(color: AppTheme.danger)),
      ),
    ]);
  }

  static const _tiers = ['F', 'E', 'D', 'C', 'B', 'A', 'S'];

  /// Opens a token market on this card reaching a higher tier by a deadline (N5).
  Future<void> _ascensionMarket() async {
    final messenger = ScaffoldMessenger.of(widget.dialogContext);
    final chit = widget.chit;
    final curIdx = _tiers.indexOf(chit.tier.toUpperCase());
    final higher = curIdx < 0
        ? _tiers
        : _tiers.sublist((curIdx + 1).clamp(0, _tiers.length));
    if (higher.isEmpty) {
      messenger.showSnackBar(const SnackBar(
          content: Text('This card is already at the top tier.'),
          backgroundColor: AppTheme.surface));
      return;
    }
    var target = higher.first;
    var days = 30;
    final ok = await showDialog<bool>(
      context: widget.dialogContext,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setState) => AlertDialog(
          backgroundColor: AppTheme.surface,
          title: const Text('Ascension market',
              style: TextStyle(color: AppTheme.textPrimary, fontSize: 17)),
          content: Column(mainAxisSize: MainAxisSize.min, children: [
            Text('Will "${chit.name}" reach this tier within $days days?',
                style:
                    const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              children: [
                for (final t in higher)
                  ChoiceChip(
                    label: Text('$t-tier'),
                    selected: target == t,
                    onSelected: (_) => setState(() => target = t),
                  ),
              ],
            ),
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
    if (ok != true) return;
    try {
      await CardMarketService.createAscensionMarket(
          chitId: chit.id,
          targetTier: target,
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

  /// Permanently deletes a card the user minted (server-guarded: minter-only,
  /// no copies held by others, not wagered/listed) and releases its source
  /// moment so it can be minted again.
  Future<void> _delete() async {
    final messenger = ScaffoldMessenger.of(widget.dialogContext);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Delete this card?',
            style: TextStyle(color: AppTheme.textPrimary)),
        content: Text(
          '${widget.chit.name} and its cutscene are permanently deleted, and '
          'your self-mint slot is freed. The original moment is released, so '
          'you can mint it again fresh. This can\'t be undone.',
          style: const TextStyle(color: AppTheme.textSecondary),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Keep it')),
          FilledButton(
              style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await MintService.deleteChit(widget.chit.id);
      if (widget.dialogContext.mounted) Navigator.pop(widget.dialogContext);
      messenger.showSnackBar(SnackBar(
          content: Text(
              '${widget.chit.name} deleted — its moment is free to mint again.'),
          backgroundColor: AppTheme.surface));
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(
          content: Text('Could not delete — $e'),
          backgroundColor: AppTheme.danger));
    } finally {
      ref.invalidate(myCollectionProvider);
    }
  }

  Future<void> _sell(TierPrice price) async {
    // Captured before the awaits: the dialog context outlives them via the
    // messenger, so no BuildContext crosses an async gap.
    final messenger = ScaffoldMessenger.of(widget.dialogContext);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('List for sale?',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 17)),
        content: Text(
          '${widget.chit.name} will be listed at its fixed Tier '
          '${widget.chit.tier} price of ${price.tokens} tokens.'
          '${price.feeBps > 0 ? ' ${price.feeBps ~/ 100}% is burned on sale — you receive ${price.netToSeller}.' : ''}'
          '\n\nWhile listed it leaves your collection (held in escrow) and '
          'can\'t battle or ascend. You can delist anytime before it sells.',
          style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('List it')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      await MarketService.listChit(widget.chit.id);
      if (widget.dialogContext.mounted) Navigator.pop(widget.dialogContext);
      messenger.showSnackBar(SnackBar(
          content:
              Text('${widget.chit.name} listed for ${price.tokens} tokens.'),
          backgroundColor: AppTheme.surface));
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(
          content: Text(MarketService.errorMessage(e)),
          backgroundColor: AppTheme.danger));
    } finally {
      ref.invalidate(myCollectionProvider);
      ref.invalidate(activeListingsProvider);
      ref.invalidate(myListingsProvider);
    }
  }

  Future<void> _delist() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(widget.dialogContext);
    try {
      await MarketService.delistListing(widget.chit.listingId!);
      if (widget.dialogContext.mounted) Navigator.pop(widget.dialogContext);
      messenger.showSnackBar(SnackBar(
          content: Text('${widget.chit.name} is back in your collection.'),
          backgroundColor: AppTheme.surface));
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(
          content: Text(MarketService.errorMessage(e)),
          backgroundColor: AppTheme.danger));
    } finally {
      ref.invalidate(myCollectionProvider);
      ref.invalidate(activeListingsProvider);
      ref.invalidate(myListingsProvider);
      ref.invalidate(tokenBalanceProvider);
    }
  }
}

/// The weekly "check for tier-ups" action (migs 136/157 — the viral upgrade).
/// Re-reads the linked posts' live engagement server-side and ascends any chit
/// whose moment has crossed a tier threshold; once per 7 days.
class _AscensionAction extends ConsumerStatefulWidget {
  const _AscensionAction();

  @override
  ConsumerState<_AscensionAction> createState() => _AscensionActionState();
}

class _AscensionActionState extends ConsumerState<_AscensionAction> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final status = ref.watch(ascensionStatusProvider).valueOrNull;
    final pending = status?.pendingReviewCount ?? 0;
    return IconButton(
      tooltip: pending > 0
          ? 'Check for tier-ups ($pending awaiting review)'
          : 'Check for tier-ups',
      icon: _busy
          ? const SizedBox(
              width: 18,
              height: 18,
              child: CircularProgressIndicator(strokeWidth: 2))
          : const Icon(Icons.trending_up),
      onPressed: _busy ? null : _checkForTierUps,
    );
  }

  Future<void> _checkForTierUps() async {
    final messenger = ScaffoldMessenger.of(context);
    final status = ref.read(ascensionStatusProvider).valueOrNull;
    if (status != null && !status.canRefresh) {
      messenger.showSnackBar(SnackBar(
          content: Text(
              'Next tier-up check unlocks ${_when(status.nextRefreshAt!)}.'),
          backgroundColor: AppTheme.surface));
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Check for tier-ups?',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 17)),
        content: const Text(
          'This re-reads your posts\' live engagement and ascends any '
          'BattleChit whose moment has kept going viral. Tiers only ever go '
          'up, and you can check once every 7 days.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 13),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Cancel')),
          FilledButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('Check now')),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    setState(() => _busy = true);
    try {
      final result = await AscensionService.refresh();
      if (!mounted) return;
      setState(() => _busy = false);
      if (result.anythingHappened) {
        ref.invalidate(myCollectionProvider);
        await _showTierUps(result);
      } else {
        messenger.showSnackBar(SnackBar(
            content: Text(result.detail ??
                'No tier-ups yet — keep sharing your moment!'),
            backgroundColor: AppTheme.surface));
      }
    } on AscensionCooldownException catch (e) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(
          content: Text(e.nextRefreshAt == null
              ? 'Ascension refresh is available once per 7 days.'
              : 'Next tier-up check unlocks ${_when(e.nextRefreshAt!)}.'),
          backgroundColor: AppTheme.surface));
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(
          content: Text('$e'), backgroundColor: AppTheme.danger));
    } finally {
      ref.invalidate(ascensionStatusProvider);
    }
  }

  Future<void> _showTierUps(AscensionResult result) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: AppTheme.surface,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 28, 24, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (result.tierUps.isNotEmpty) ...[
                const Icon(Icons.auto_awesome, color: Colors.amber, size: 44),
                const SizedBox(height: 10),
                const Text('GONE VIRAL!',
                    style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.5)),
                const SizedBox(height: 4),
                Text(
                  result.tierUps.length == 1
                      ? 'Your BattleChit ascended!'
                      : '${result.tierUps.length} BattleChits ascended!',
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 13),
                ),
                const SizedBox(height: 16),
                for (final up in result.tierUps) _tierUpRow(up, live: true),
              ],
              if (result.queuedForReview.isNotEmpty) ...[
                if (result.tierUps.isNotEmpty) const SizedBox(height: 16),
                const Text('Held for review',
                    style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 4),
                const Text(
                  'A jump this big gets a quick manual check first — the '
                  'tier updates once it clears.',
                  textAlign: TextAlign.center,
                  style:
                      TextStyle(color: AppTheme.textSecondary, fontSize: 12),
                ),
                const SizedBox(height: 10),
                for (final up in result.queuedForReview)
                  _tierUpRow(up, live: false),
              ],
              const SizedBox(height: 12),
              FilledButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                    result.tierUps.isNotEmpty ? 'Awesome!' : 'Got it'),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _tierUpRow(AscensionTierUp up, {required bool live}) {
    final accent = live ? Colors.amber : AppTheme.secondary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Flexible(
            child: Text(up.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600)),
          ),
          const SizedBox(width: 10),
          Text('Tier ${up.fromTier}',
              style:
                  const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: Icon(Icons.arrow_forward, size: 14, color: accent),
          ),
          Text('Tier ${up.toTier}',
              style: TextStyle(
                  color: accent, fontSize: 14, fontWeight: FontWeight.w800)),
        ],
      ),
    );
  }

  String _when(DateTime at) {
    final local = at.toLocal();
    final now = DateTime.now();
    final days = local.difference(now).inDays;
    final clock = TimeOfDay.fromDateTime(local).format(context);
    if (days < 1 && local.day == now.day) return 'today at $clock';
    return 'on ${local.month}/${local.day} at $clock';
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
                    child: _pill('Tap to finish', AppTheme.secondary),
                  )
                else if (chit.isListed)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: _pill('Listed', AppTheme.success),
                  )
                else if (chit.isStarter)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: _pill('Starter', AppTheme.textSecondary),
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

/// The onboarding beat the playset exists to set up (Playset spec S2): you have a
/// real deck already — now put YOUR moment in it.
class _MintYourMomentBanner extends StatelessWidget {
  const _MintYourMomentBanner({required this.onMint, required this.onBuildDeck});
  final VoidCallback onMint;
  final VoidCallback onBuildDeck;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.primary.withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.35)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Your starter deck is ready',
              style: TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w800)),
          const SizedBox(height: 6),
          const Text(
            'Every account gets the Standard Playset — 30 cards, 2 copies each, '
            'enough for thousands of legal decks. Now add the card only you can '
            'make: mint a moment you posted.',
            style: TextStyle(
                color: AppTheme.textSecondary, fontSize: 12.5, height: 1.5),
          ),
          const SizedBox(height: 12),
          Wrap(spacing: 10, runSpacing: 8, children: [
            FilledButton.icon(
              onPressed: onMint,
              icon: const Icon(Icons.auto_awesome, size: 18),
              label: const Text('Mint your moment'),
            ),
            OutlinedButton.icon(
              onPressed: onBuildDeck,
              icon: const Icon(Icons.style_outlined, size: 18),
              label: const Text('Build a deck'),
            ),
          ]),
        ],
      ),
    );
  }
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
