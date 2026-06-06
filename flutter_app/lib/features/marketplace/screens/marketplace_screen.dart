import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/marketplace_providers.dart';

class MarketplaceScreen extends ConsumerStatefulWidget {
  final String? initialTab;
  const MarketplaceScreen({super.key, this.initialTab});

  @override
  ConsumerState<MarketplaceScreen> createState() => _MarketplaceScreenState();
}

class _MarketplaceScreenState extends ConsumerState<MarketplaceScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab == 'chits' ? 1 : 0,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: const Text('Marketplace', style: TextStyle(color: AppTheme.textPrimary)),
        iconTheme: const IconThemeData(color: AppTheme.textPrimary),
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: AppTheme.primary,
          labelColor: AppTheme.primary,
          unselectedLabelColor: AppTheme.textSecondary,
          tabs: const [Tab(text: 'Characters'), Tab(text: 'Battle Chits')],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [_CharactersTab(), _ChitsTab()],
      ),
    );
  }
}

// ─── Characters Tab ───────────────────────────────────────────────────────────

class _CharactersTab extends ConsumerWidget {
  const _CharactersTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offeringsAsync = ref.watch(likenessOfferingsProvider);
    final listingsAsync = ref.watch(cardListingsProvider);
    final myCardsAsync = ref.watch(myLikenessCardsProvider);

    return RefreshIndicator(
      color: AppTheme.primary,
      backgroundColor: AppTheme.surface,
      onRefresh: () async {
        ref.invalidate(likenessOfferingsProvider);
        ref.invalidate(cardListingsProvider);
        ref.invalidate(myLikenessCardsProvider);
      },
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const _SectionHeader('Featured Offerings'),
          offeringsAsync.when(
            data: (offerings) => offerings.isEmpty
                ? const _EmptyState('No active offerings yet.')
                : Column(
                    children: offerings
                        .map((o) => _OfferingTile(offering: o))
                        .toList()),
            loading: () => const _LoadingRows(),
            error: (e, _) => _ErrorState(e.toString()),
          ),
          const SizedBox(height: 24),
          const _SectionHeader('Secondary Market'),
          listingsAsync.when(
            data: (listings) => listings.isEmpty
                ? const _EmptyState('No cards listed for sale.')
                : Column(
                    children:
                        listings.map((l) => _ListingTile(listing: l)).toList()),
            loading: () => const _LoadingRows(),
            error: (e, _) => _ErrorState(e.toString()),
          ),
          const SizedBox(height: 24),
          const _SectionHeader('My Cards'),
          myCardsAsync.when(
            data: (cards) => cards.isEmpty
                ? const _EmptyState("You don't own any cards yet. Browse offerings above.")
                : Column(
                    children: cards
                        .map((c) => _MyCardTile(card: c))
                        .toList()),
            loading: () => const _LoadingRows(),
            error: (e, _) => _ErrorState(e.toString()),
          ),
          const SizedBox(height: 32),
          const _DisclaimerBanner(),
        ],
      ),
    );
  }
}

class _OfferingTile extends StatelessWidget {
  final Map<String, dynamic> offering;
  const _OfferingTile({required this.offering});

  @override
  Widget build(BuildContext context) {
    final profile = offering['profiles'] as Map<String, dynamic>?;
    final minted = (offering['cards_minted'] as num?)?.toInt() ?? 0;
    final total = (offering['card_print_run'] as num?)?.toInt() ?? 1;
    final priceUsd =
        ((offering['price_per_card_usd_cents'] as num?)?.toInt() ?? 0) / 100;

    return Card(
      color: AppTheme.surface,
      margin: const EdgeInsets.only(bottom: 12),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: const BorderSide(color: AppTheme.cardBorder),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => context.push('/marketplace/offering/${offering['id']}'),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              CircleAvatar(
                radius: 28,
                backgroundColor: AppTheme.primary.withValues(alpha: 0.2),
                backgroundImage: offering['character_image_url'] != null
                    ? NetworkImage(offering['character_image_url'] as String)
                    : null,
                child: offering['character_image_url'] == null
                    ? Text(
                        (offering['character_name'] as String? ?? '?')[0]
                            .toUpperCase(),
                        style: const TextStyle(color: AppTheme.primary, fontWeight: FontWeight.bold))
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(offering['character_name'] as String? ?? '',
                        style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontWeight: FontWeight.bold,
                            fontSize: 15)),
                    Text(
                        '${profile?['username'] ?? 'Unknown'} · ${(offering['archetype'] as String? ?? '').toUpperCase()}',
                        style: const TextStyle(
                            color: AppTheme.textSecondary, fontSize: 12)),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: total > 0 ? minted / total : 0,
                      backgroundColor: AppTheme.cardBorder,
                      color: AppTheme.primary,
                    ),
                    const SizedBox(height: 4),
                    Text('$minted / $total minted',
                        style: const TextStyle(
                            color: AppTheme.textSecondary, fontSize: 11)),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text('\$${priceUsd.toStringAsFixed(2)}',
                      style: const TextStyle(
                          color: AppTheme.success,
                          fontWeight: FontWeight.bold,
                          fontSize: 16)),
                  const Text('per card',
                      style: TextStyle(
                          color: AppTheme.textSecondary, fontSize: 11)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ListingTile extends StatelessWidget {
  final Map<String, dynamic> listing;
  const _ListingTile({required this.listing});

  @override
  Widget build(BuildContext context) {
    final card = listing['likeness_cards'] as Map<String, dynamic>?;
    final offn = listing['likeness_offerings'] as Map<String, dynamic>?;
    final cardNum = (card?['card_number'] as num?)?.toInt();
    final rarity = card?['rarity'] as String? ?? 'standard';
    final priceUsd =
        ((listing['asking_price_usd_cents'] as num?)?.toInt() ?? 0) / 100;

    return Card(
      color: AppTheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: AppTheme.cardBorder),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => context.push('/marketplace/card/${card?['id'] ?? ''}'),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: _rarityColor(rarity).withValues(alpha: 0.2),
                backgroundImage: offn?['character_image_url'] != null
                    ? NetworkImage(offn!['character_image_url'] as String)
                    : null,
                child: offn?['character_image_url'] == null
                    ? Text('#${cardNum ?? '?'}',
                        style: TextStyle(color: _rarityColor(rarity), fontSize: 11))
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(offn?['character_name'] as String? ?? 'Unknown',
                        style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontWeight: FontWeight.w600)),
                    Row(
                      children: [
                        _RarityBadge(rarity),
                        if (cardNum != null)
                          Padding(
                            padding: const EdgeInsets.only(left: 6),
                            child: Text('Card #$cardNum',
                                style: const TextStyle(
                                    color: AppTheme.textSecondary, fontSize: 12)),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              Text('\$${priceUsd.toStringAsFixed(2)}',
                  style: const TextStyle(
                      color: AppTheme.success,
                      fontWeight: FontWeight.bold,
                      fontSize: 15)),
            ],
          ),
        ),
      ),
    );
  }
}

class _MyCardTile extends StatelessWidget {
  final Map<String, dynamic> card;
  const _MyCardTile({required this.card});

  @override
  Widget build(BuildContext context) {
    final offn = card['likeness_offerings'] as Map<String, dynamic>?;
    final cardNum = (card['card_number'] as num?)?.toInt();
    final rarity = card['rarity'] as String? ?? 'standard';

    return Card(
      color: AppTheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: AppTheme.cardBorder),
      ),
      child: ListTile(
        leading: CircleAvatar(
          radius: 22,
          backgroundColor: _rarityColor(rarity).withValues(alpha: 0.2),
          child: Text('#${cardNum ?? '?'}',
              style: TextStyle(color: _rarityColor(rarity), fontSize: 12, fontWeight: FontWeight.bold)),
        ),
        title: Text(offn?['character_name'] as String? ?? 'Unknown',
            style: const TextStyle(color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
        subtitle: _RarityBadge(rarity),
        trailing: TextButton(
          onPressed: () => context.push('/marketplace/card/${card['id']}'),
          child: const Text('View', style: TextStyle(color: AppTheme.primary)),
        ),
      ),
    );
  }
}

Color _rarityColor(String rarity) {
  switch (rarity) {
    case 'legendary':
      return const Color(0xFFFFD700);
    case 'rare':
      return const Color(0xFF9146FF);
    default:
      return AppTheme.textSecondary;
  }
}

class _RarityBadge extends StatelessWidget {
  final String rarity;
  const _RarityBadge(this.rarity);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: _rarityColor(rarity).withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        rarity[0].toUpperCase() + rarity.substring(1),
        style: TextStyle(
            color: _rarityColor(rarity), fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _DisclaimerBanner extends StatelessWidget {
  const _DisclaimerBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: const Text(
        'Character cards are collectible game items. Owning a card grants Battle '
        'eligibility and a share of in-game match rewards for that character. '
        'Cards have no guaranteed monetary value and are not financial instruments.',
        style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
        textAlign: TextAlign.center,
      ),
    );
  }
}

// ─── Chits Tab ────────────────────────────────────────────────────────────────

class _ChitsTab extends ConsumerStatefulWidget {
  const _ChitsTab();

  @override
  ConsumerState<_ChitsTab> createState() => _ChitsTabState();
}

class _ChitsTabState extends ConsumerState<_ChitsTab>
    with SingleTickerProviderStateMixin {
  late final TabController _sub;

  @override
  void initState() {
    super.initState();
    _sub = TabController(length: 3, vsync: this);
  }

  @override
  void dispose() {
    _sub.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TabBar(
          controller: _sub,
          indicatorColor: AppTheme.secondary,
          labelColor: AppTheme.secondary,
          unselectedLabelColor: AppTheme.textSecondary,
          tabs: const [Tab(text: 'Earn'), Tab(text: 'Browse'), Tab(text: 'My Chits')],
        ),
        Expanded(
          child: TabBarView(
            controller: _sub,
            children: const [_ChitsEarnTab(), _ChitsBrowseTab(), _MyChitsTab()],
          ),
        ),
      ],
    );
  }
}

class _ChitsEarnTab extends ConsumerWidget {
  const _ChitsEarnTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final defsAsync = ref.watch(chitDefinitionsProvider);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3)),
          ),
          child: const Text(
            'The rarest chits can only be earned by grinding matches. '
            'Win more battles to increase your chances of a legendary drop.',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 13),
          ),
        ),
        const SizedBox(height: 16),
        defsAsync.when(
          data: (defs) => Column(
            children: defs.map((d) => _ChitDefinitionRow(def: d)).toList(),
          ),
          loading: () => const _LoadingRows(),
          error: (e, _) => _ErrorState(e.toString()),
        ),
      ],
    );
  }
}

class _ChitDefinitionRow extends StatelessWidget {
  final Map<String, dynamic> def;
  const _ChitDefinitionRow({required this.def});

  @override
  Widget build(BuildContext context) {
    final rarity = def['rarity'] as String? ?? 'common';
    final dropRate = def['rng_drop_rate'] as double?;
    final fromChallenges = def['can_earn_from_challenges'] as bool? ?? false;
    final fromRng = def['can_earn_from_match_rng'] as bool? ?? false;

    String how;
    if (fromRng && fromChallenges) {
      how = 'Challenges + Match wins';
    } else if (fromRng) {
      how = 'Match wins';
    } else if (fromChallenges) {
      how = 'Challenges';
    } else {
      how = 'Events / Gift';
    }

    return Card(
      color: AppTheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: AppTheme.cardBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            _ChitRarityDot(rarity),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(def['name'] as String? ?? '',
                      style: const TextStyle(
                          color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
                  Text(def['description'] as String? ?? '',
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 12)),
                  Text('Earn: $how',
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 11)),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                _RarityBadge(rarity),
                if (dropRate != null)
                  Text('${(dropRate * 100).toStringAsFixed(1)}%',
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ChitRarityDot extends StatelessWidget {
  final String rarity;
  const _ChitRarityDot(this.rarity);

  @override
  Widget build(BuildContext context) {
    final color = switch (rarity) {
      'mythic' => const Color(0xFFFF4757),
      'legendary' => const Color(0xFFFFD700),
      'epic' => const Color(0xFF9146FF),
      'rare' => AppTheme.primary,
      'uncommon' => AppTheme.secondary,
      _ => AppTheme.textSecondary,
    };
    return Container(
      width: 10,
      height: 10,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }
}

class _ChitsBrowseTab extends ConsumerWidget {
  const _ChitsBrowseTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final listingsAsync = ref.watch(chitListingsProvider);

    return RefreshIndicator(
      color: AppTheme.primary,
      backgroundColor: AppTheme.surface,
      onRefresh: () async => ref.invalidate(chitListingsProvider),
      child: listingsAsync.when(
        data: (listings) => listings.isEmpty
            ? const Center(
                child: Text('No chits listed for sale.',
                    style: TextStyle(color: AppTheme.textSecondary)))
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: listings.length,
                itemBuilder: (_, i) => _ChitListingTile(listing: listings[i]),
              ),
        loading: () => const Center(child: CircularProgressIndicator(color: AppTheme.primary)),
        error: (e, _) => Center(child: _ErrorState(e.toString())),
      ),
    );
  }
}

class _ChitListingTile extends ConsumerWidget {
  final Map<String, dynamic> listing;
  const _ChitListingTile({required this.listing});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final def = listing['battle_chit_definitions'] as Map<String, dynamic>?;
    final rarity = def?['rarity'] as String? ?? 'common';
    final qty = (listing['quantity_listed'] as num?)?.toInt() ?? 1;
    final price = (listing['price_per_unit_tokens'] as num?)?.toInt() ?? 0;

    return Card(
      color: AppTheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: AppTheme.cardBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            _ChitRarityDot(rarity),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(def?['name'] as String? ?? '',
                      style: const TextStyle(
                          color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
                  Text(def?['description'] as String? ?? '',
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 12)),
                  Text('Qty: $qty',
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 11)),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text('$price tokens',
                    style: const TextStyle(
                        color: AppTheme.success, fontWeight: FontWeight.bold)),
                const Text('each',
                    style: TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MyChitsTab extends ConsumerWidget {
  const _MyChitsTab();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final chitsAsync = ref.watch(myChitsProvider);

    return RefreshIndicator(
      color: AppTheme.primary,
      backgroundColor: AppTheme.surface,
      onRefresh: () async => ref.invalidate(myChitsProvider),
      child: chitsAsync.when(
        data: (chits) => chits.isEmpty
            ? const Center(
                child: Text('No chits in your inventory.',
                    style: TextStyle(color: AppTheme.textSecondary)))
            : ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: chits.length,
                itemBuilder: (_, i) => _MyChitTile(chit: chits[i]),
              ),
        loading: () => const Center(child: CircularProgressIndicator(color: AppTheme.primary)),
        error: (e, _) => Center(child: _ErrorState(e.toString())),
      ),
    );
  }
}

class _MyChitTile extends StatelessWidget {
  final Map<String, dynamic> chit;
  const _MyChitTile({required this.chit});

  @override
  Widget build(BuildContext context) {
    final def = chit['battle_chit_definitions'] as Map<String, dynamic>?;
    final rarity = def?['rarity'] as String? ?? 'common';
    final qty = (chit['quantity'] as num?)?.toInt() ?? 0;
    final canSell = def?['can_buy_in_marketplace'] as bool? ?? false;

    return Card(
      color: AppTheme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: const BorderSide(color: AppTheme.cardBorder),
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Row(
          children: [
            _ChitRarityDot(rarity),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(def?['name'] as String? ?? '',
                      style: const TextStyle(
                          color: AppTheme.textPrimary, fontWeight: FontWeight.w600)),
                  Text('Qty: $qty · ${def?['description'] ?? ''}',
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 12)),
                ],
              ),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                OutlinedButton(
                  onPressed: () => context.push('/battle'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.primary,
                    side: const BorderSide(color: AppTheme.primary),
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                  ),
                  child: const Text('Use', style: TextStyle(fontSize: 12)),
                ),
                if (canSell) ...[
                  const SizedBox(width: 6),
                  OutlinedButton(
                    onPressed: () {
                      // TODO: open listing price bottom sheet
                    },
                    style: OutlinedButton.styleFrom(
                      foregroundColor: AppTheme.secondary,
                      side: const BorderSide(color: AppTheme.secondary),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                    ),
                    child: const Text('List', style: TextStyle(fontSize: 12)),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Offering Detail ──────────────────────────────────────────────────────────

class OfferingDetailScreen extends ConsumerWidget {
  final String offeringId;
  const OfferingDetailScreen({super.key, required this.offeringId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final offeringAsync = ref.watch(offeringDetailProvider(offeringId));

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: const Text('Offering', style: TextStyle(color: AppTheme.textPrimary)),
        iconTheme: const IconThemeData(color: AppTheme.textPrimary),
      ),
      body: offeringAsync.when(
        data: (offering) => offering == null
            ? const Center(child: Text('Offering not found.', style: TextStyle(color: AppTheme.textSecondary)))
            : _OfferingDetail(offering: offering),
        loading: () => const Center(child: CircularProgressIndicator(color: AppTheme.primary)),
        error: (e, _) => Center(child: Text(e.toString(), style: const TextStyle(color: AppTheme.danger))),
      ),
    );
  }
}

class _OfferingDetail extends ConsumerWidget {
  final Map<String, dynamic> offering;
  const _OfferingDetail({required this.offering});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = offering['profiles'] as Map<String, dynamic>?;
    final minted = (offering['cards_minted'] as num?)?.toInt() ?? 0;
    final total = (offering['card_print_run'] as num?)?.toInt() ?? 1;
    final priceUsd =
        ((offering['price_per_card_usd_cents'] as num?)?.toInt() ?? 0) / 100;
    final pctOffered = (offering['total_pct_offered'] as num?)?.toDouble() ?? 0;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (offering['character_image_url'] != null)
          ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: Image.network(
              offering['character_image_url'] as String,
              height: 200,
              fit: BoxFit.cover,
            ),
          ),
        const SizedBox(height: 16),
        Text(offering['character_name'] as String? ?? '',
            style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 24,
                fontWeight: FontWeight.bold)),
        Text(
            '${(offering['archetype'] as String? ?? '').toUpperCase()} · by ${profile?['username'] ?? 'Unknown'}',
            style: const TextStyle(color: AppTheme.textSecondary)),
        const SizedBox(height: 16),
        _InfoRow('Total % offered', '${pctOffered.toStringAsFixed(2)}%'),
        _InfoRow('Cards remaining', '${total - minted} of $total'),
        _InfoRow('Price per card', '\$${priceUsd.toStringAsFixed(2)}'),
        const _InfoRow('Rarity breakdown', '#1 Legendary · #2–10 Rare · #11+ Standard'),
        const SizedBox(height: 16),
        LinearProgressIndicator(
          value: total > 0 ? minted / total : 0,
          backgroundColor: AppTheme.cardBorder,
          color: AppTheme.primary,
          minHeight: 8,
        ),
        const SizedBox(height: 4),
        Text('$minted / $total minted',
            style: const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            textAlign: TextAlign.center),
        const SizedBox(height: 24),
        if (total - minted > 0)
          FilledButton(
            onPressed: () => _purchaseCard(context, ref),
            style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
            child: const Text('Get a Card'),
          ),
        const SizedBox(height: 16),
        if (profile?['username'] != null)
          TextButton(
            onPressed: () => context.push('/u/${profile!['username']}'),
            child: const Text('View Creator Profile',
                style: TextStyle(color: AppTheme.primary)),
          ),
        const SizedBox(height: 24),
        const _DisclaimerBanner(),
      ],
    );
  }

  Future<void> _purchaseCard(BuildContext context, WidgetRef ref) async {
    try {
      final resp = await Supabase.instance.client.functions.invoke(
        'likeness-purchase-card',
        body: {'offering_id': offering['id']},
      );
      if (!context.mounted) return;
      final cardNum = resp.data?['card_number'];
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('You minted Card #$cardNum!')),
      );
      ref.invalidate(likenessOfferingsProvider);
      ref.invalidate(myLikenessCardsProvider);
    } catch (e) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Purchase failed: $e')),
      );
    }
  }
}

class _InfoRow extends StatelessWidget {
  final String label;
  final String value;
  const _InfoRow(this.label, this.value);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label,
              style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
          Text(value,
              style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontWeight: FontWeight.w600,
                  fontSize: 13)),
        ],
      ),
    );
  }
}

// ─── Card Detail ──────────────────────────────────────────────────────────────

class CardDetailScreen extends ConsumerWidget {
  final String cardId;
  const CardDetailScreen({super.key, required this.cardId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final cardAsync = ref.watch(cardDetailProvider(cardId));
    final transfersAsync = ref.watch(cardTransfersProvider(cardId));
    final userId = Supabase.instance.client.auth.currentUser?.id;

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: const Text('Card Detail', style: TextStyle(color: AppTheme.textPrimary)),
        iconTheme: const IconThemeData(color: AppTheme.textPrimary),
      ),
      body: cardAsync.when(
        data: (card) {
          if (card == null) {
            return const Center(
                child: Text('Card not found.',
                    style: TextStyle(color: AppTheme.textSecondary)));
          }
          final offn = card['likeness_offerings'] as Map<String, dynamic>?;
          final rarity = card['rarity'] as String? ?? 'standard';
          final cardNum = (card['card_number'] as num?)?.toInt();
          final isOwner = userId != null && card['current_owner_id'] == userId;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              Center(
                child: CircleAvatar(
                  radius: 56,
                  backgroundColor: _rarityColor(rarity).withValues(alpha: 0.2),
                  backgroundImage: offn?['character_image_url'] != null
                      ? NetworkImage(offn!['character_image_url'] as String)
                      : null,
                  child: offn?['character_image_url'] == null
                      ? Text('#${cardNum ?? '?'}',
                          style: TextStyle(
                              color: _rarityColor(rarity),
                              fontSize: 20,
                              fontWeight: FontWeight.bold))
                      : null,
                ),
              ),
              const SizedBox(height: 12),
              Center(
                  child: Text(offn?['character_name'] as String? ?? '',
                      style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 22,
                          fontWeight: FontWeight.bold))),
              Center(child: _RarityBadge(rarity)),
              if (cardNum != null)
                Center(
                    child: Text('Card #$cardNum',
                        style: const TextStyle(
                            color: AppTheme.textSecondary, fontSize: 13))),
              const SizedBox(height: 24),
              if (isOwner) ...[
                Row(
                  children: [
                    Expanded(
                      child: FilledButton(
                        onPressed: () => context.push('/battle'),
                        style: FilledButton.styleFrom(backgroundColor: AppTheme.primary),
                        child: const Text('Use in Battle'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () {
                          // TODO: open listing price sheet
                        },
                        style: OutlinedButton.styleFrom(
                          foregroundColor: AppTheme.secondary,
                          side: const BorderSide(color: AppTheme.secondary),
                        ),
                        child: const Text('List for Sale'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
              ],
              const Text('Transfer History',
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontWeight: FontWeight.bold,
                      fontSize: 16)),
              const SizedBox(height: 8),
              transfersAsync.when(
                data: (transfers) => transfers.isEmpty
                    ? const Text('No transfers yet.',
                        style: TextStyle(color: AppTheme.textSecondary))
                    : Column(
                        children: transfers.map((t) {
                          final toUser = t['to_profile'] as Map<String, dynamic>?;
                          final type = t['transfer_type'] as String? ?? 'mint';
                          final price =
                              ((t['usd_cents_paid'] as num?)?.toInt() ?? 0) / 100;
                          return ListTile(
                            dense: true,
                            leading: const Icon(Icons.swap_horiz,
                                color: AppTheme.textSecondary, size: 16),
                            title: Text(
                                '${type == 'mint' ? 'Minted' : 'Sold'} to ${toUser?['username'] ?? 'unknown'}',
                                style: const TextStyle(
                                    color: AppTheme.textPrimary, fontSize: 13)),
                            trailing: price > 0
                                ? Text('\$${price.toStringAsFixed(2)}',
                                    style: const TextStyle(
                                        color: AppTheme.success, fontSize: 12))
                                : null,
                          );
                        }).toList()),
                loading: () => const _LoadingRows(),
                error: (e, _) => _ErrorState(e.toString()),
              ),
            ],
          );
        },
        loading: () => const Center(child: CircularProgressIndicator(color: AppTheme.primary)),
        error: (e, _) => Center(child: Text(e.toString(), style: const TextStyle(color: AppTheme.danger))),
      ),
    );
  }
}

// ─── Shared helpers ───────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Text(title,
          style: const TextStyle(
              color: AppTheme.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.bold)),
    );
  }
}

class _LoadingRows extends StatelessWidget {
  const _LoadingRows();

  @override
  Widget build(BuildContext context) {
    return const Column(
      children: [
        LinearProgressIndicator(color: AppTheme.primary),
        SizedBox(height: 8),
      ],
    );
  }
}

class _EmptyState extends StatelessWidget {
  final String message;
  const _EmptyState(this.message);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Text(message,
          style: const TextStyle(color: AppTheme.textSecondary),
          textAlign: TextAlign.center),
    );
  }
}

class _ErrorState extends StatelessWidget {
  final String message;
  const _ErrorState(this.message);

  @override
  Widget build(BuildContext context) {
    return Text('Error: $message',
        style: const TextStyle(color: AppTheme.danger, fontSize: 12));
  }
}
