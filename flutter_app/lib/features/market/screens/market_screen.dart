import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/card_face.dart';
import '../../auth/providers/auth_provider.dart';
import '../../collection/providers/collection_providers.dart';
import '../../wallet/providers/wallet_providers.dart';
import '../providers/market_providers.dart';
import '../../../core/widgets/n_back_button.dart';

/// `/market` — the fixed-price chit marketplace (token lane). Browse every
/// active listing, buy with tokens, delist your own. Prices are config-fixed
/// per tier (never supply/demand — Hard Rule 40); the A/S fee is burned.
class MarketScreen extends ConsumerWidget {
  const MarketScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listings = ref.watch(activeListingsProvider);
    final balance = ref.watch(tokenBalanceProvider);
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: const NBackButton(fallback: '/battle'),
        backgroundColor: AppTheme.background,
        title: const Text('Chit Market'),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: Center(
              child: balance.maybeWhen(
                data: (b) => _balanceChip(context, b.availableTokens),
                orElse: () => const SizedBox.shrink(),
              ),
            ),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () {
          ref.invalidate(tokenBalanceProvider);
          return ref.refresh(activeListingsProvider.future);
        },
        child: listings.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (e, _) => _message(
            icon: Icons.error_outline,
            color: AppTheme.danger,
            title: 'Could not load the market',
            detail: '$e',
          ),
          data: (rows) => rows.isEmpty
              ? _message(
                  icon: Icons.storefront_outlined,
                  color: AppTheme.textSecondary,
                  title: 'Nothing listed right now',
                  detail:
                      'Cards you list from your collection show up here at their '
                      'fixed tier price.',
                )
              : _grid(context, ref, rows),
        ),
      ),
    );
  }

  Widget _balanceChip(BuildContext context, int tokens) => GestureDetector(
        onTap: () => context.go('/wallet'),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: AppTheme.cardBorder),
          ),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.toll, size: 14, color: AppTheme.secondary),
            const SizedBox(width: 5),
            Text('$tokens',
                style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700)),
          ]),
        ),
      );

  Widget _grid(BuildContext context, WidgetRef ref, List<MarketListing> rows) {
    final myId = ref.watch(currentUserProvider)?.id;
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      physics: const AlwaysScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 220,
        childAspectRatio: 0.58,
        crossAxisSpacing: 14,
        mainAxisSpacing: 14,
      ),
      itemCount: rows.length,
      itemBuilder: (ctx, i) => _ListingCard(
        listing: rows[i],
        isOwn: rows[i].sellerUserId == myId,
        onTap: () => _showListing(ctx, ref, rows[i], isOwn: rows[i].sellerUserId == myId),
      ),
    );
  }

  void _showListing(BuildContext context, WidgetRef ref, MarketListing l,
      {required bool isOwn}) {
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
                  name: l.name,
                  chitType: l.chitType,
                  family: l.family,
                  tier: l.tier,
                  auraCost: l.auraCost,
                  atk: l.atk,
                  hp: l.hp,
                  keywords: l.keywords,
                  cardArtUrl: l.cardArtUrl,
                  minterHandle: l.minterHandle,
                  sourcePlatform: l.sourcePlatform,
                  rulesText: l.rulesText,
                  flavor: l.flavor,
                  serial: l.serial,
                ),
              ),
              const SizedBox(height: 12),
              _priceLine(l),
              const SizedBox(height: 12),
              if (isOwn)
                FilledButton.icon(
                  style: FilledButton.styleFrom(backgroundColor: AppTheme.danger),
                  onPressed: () => _delist(ctx, ref, l),
                  icon: const Icon(Icons.remove_shopping_cart_outlined),
                  label: const Text('Delist — return it to my collection'),
                )
              else
                _BuyButton(listing: l, dialogContext: ctx),
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

  Widget _priceLine(MarketListing l) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Text(
          'Tier ${l.tier} · fixed price ${l.priceTokens} tokens'
          '${l.feeBps > 0 ? ' · ${l.feeBps ~/ 100}% burned on sale' : ''}',
          style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600),
        ),
      );

  Future<void> _delist(
      BuildContext dialogContext, WidgetRef ref, MarketListing l) async {
    final messenger = ScaffoldMessenger.of(dialogContext);
    try {
      await MarketService.delistListing(l.id);
      if (dialogContext.mounted) Navigator.pop(dialogContext);
      messenger.showSnackBar(SnackBar(
          content: Text('${l.name} returned to your collection.'),
          backgroundColor: AppTheme.surface));
    } catch (e) {
      messenger.showSnackBar(SnackBar(
          content: Text(MarketService.errorMessage(e)),
          backgroundColor: AppTheme.danger));
    } finally {
      ref.invalidate(activeListingsProvider);
      ref.invalidate(myListingsProvider);
      ref.invalidate(myCollectionProvider);
    }
  }

  Widget _message(
      {required IconData icon,
      required Color color,
      required String title,
      required String detail}) {
    return ListView(children: [
      const SizedBox(height: 120),
      Icon(icon, size: 48, color: color),
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
            style:
                const TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
      ),
    ]);
  }
}

/// Buy button with its own busy state so a double-tap can't double-fire
/// (the RPC is idempotent server-side regardless).
class _BuyButton extends ConsumerStatefulWidget {
  const _BuyButton({required this.listing, required this.dialogContext});
  final MarketListing listing;
  final BuildContext dialogContext;

  @override
  ConsumerState<_BuyButton> createState() => _BuyButtonState();
}

class _BuyButtonState extends ConsumerState<_BuyButton> {
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final balance = ref.watch(tokenBalanceProvider).valueOrNull;
    final affordable =
        balance != null && balance.availableTokens >= widget.listing.priceTokens;
    return Column(mainAxisSize: MainAxisSize.min, children: [
      FilledButton.icon(
        onPressed: _busy || !affordable ? null : _buy,
        icon: _busy
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Icon(Icons.shopping_cart_checkout),
        label: Text('Buy for ${widget.listing.priceTokens} tokens'),
      ),
      if (balance != null && !affordable)
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
            'Not enough tokens (you have ${balance.availableTokens}).',
            style: const TextStyle(color: AppTheme.danger, fontSize: 12),
          ),
        ),
    ]);
  }

  Future<void> _buy() async {
    setState(() => _busy = true);
    final messenger = ScaffoldMessenger.of(widget.dialogContext);
    try {
      await MarketService.buyListing(widget.listing.id);
      if (widget.dialogContext.mounted) Navigator.pop(widget.dialogContext);
      messenger.showSnackBar(SnackBar(
          content: Text(
              '${widget.listing.name} is yours — it\'s in your collection.'),
          backgroundColor: AppTheme.surface));
    } catch (e) {
      if (mounted) setState(() => _busy = false);
      messenger.showSnackBar(SnackBar(
          content: Text(MarketService.errorMessage(e)),
          backgroundColor: AppTheme.danger));
    } finally {
      ref.invalidate(activeListingsProvider);
      ref.invalidate(tokenBalanceProvider);
      ref.invalidate(myCollectionProvider);
    }
  }
}

class _ListingCard extends StatelessWidget {
  const _ListingCard(
      {required this.listing, required this.isOwn, this.onTap});
  final MarketListing listing;
  final bool isOwn;
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
              color: isOwn ? AppTheme.secondary : AppTheme.cardBorder),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (listing.cardArtUrl != null)
                    Image.network(listing.cardArtUrl!,
                        fit: BoxFit.cover,
                        errorBuilder: (_, __, ___) => _artFallback())
                  else
                    _artFallback(),
                  Positioned(
                    top: 8,
                    right: 8,
                    child: _pill('Tier ${listing.tier}', AppTheme.primary),
                  ),
                  if (isOwn)
                    Positioned(
                      top: 8,
                      left: 8,
                      child: _pill('Yours', AppTheme.secondary),
                    ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(10),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(listing.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 2),
                  Text(
                    '${listing.chitType == 'spell_moment' ? 'Spell' : 'Creature'}'
                    '${listing.family.isEmpty ? '' : ' · ${listing.family}'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 11),
                  ),
                  const SizedBox(height: 8),
                  Row(children: [
                    const Icon(Icons.toll, size: 14, color: AppTheme.secondary),
                    const SizedBox(width: 4),
                    Text('${listing.priceTokens}',
                        style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w700)),
                    const Spacer(),
                    if (listing.minterHandle != null)
                      Flexible(
                        child: Text(listing.minterHandle!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                                color: AppTheme.textSecondary, fontSize: 10)),
                      ),
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
          child:
              Icon(Icons.auto_awesome, color: AppTheme.textSecondary, size: 32),
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
}
