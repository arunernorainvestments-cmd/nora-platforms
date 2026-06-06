import 'package:flutter/material.dart';

// Doc 3 — Card Marketplace (likeness_cards secondary market).
// Full implementation pending Doc 3 session.
class CardMarketplaceScreen extends StatelessWidget {
  const CardMarketplaceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Card Marketplace')),
      body: const Center(child: Text('Coming soon')),
    );
  }
}

class CardDetailScreen extends StatelessWidget {
  final String cardId;
  const CardDetailScreen({super.key, required this.cardId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Card Detail')),
      body: const Center(child: Text('Coming soon')),
    );
  }
}

class OfferingDetailScreen extends StatelessWidget {
  final String offeringId;
  const OfferingDetailScreen({super.key, required this.offeringId});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Offering Detail')),
      body: const Center(child: Text('Coming soon')),
    );
  }
}
