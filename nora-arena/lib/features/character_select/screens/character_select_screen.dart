import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/config/theme.dart';
import '../../license_sync/providers/license_sync_providers.dart';

/// Pick a fighter from your imported (licensed) characters before a battle.
/// Ownership-gated: only characters backed by an active license appear here,
/// because [unlockedCharactersProvider] is sourced from verified licenses.
class CharacterSelectScreen extends ConsumerWidget {
  const CharacterSelectScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(unlockedCharactersProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Choose your Fighter'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add_link),
            tooltip: 'Sync licenses',
            onPressed: () => context.push('/license-sync'),
          ),
        ],
      ),
      body: async.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, __) =>
            const Center(child: Text('Could not load your characters.')),
        data: (characters) {
          if (characters.isEmpty) {
            return Center(
              child: TextButton(
                onPressed: () => context.push('/license-sync'),
                child: const Text('No fighters yet — import a license'),
              ),
            );
          }
          return GridView.builder(
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              childAspectRatio: 0.78,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemCount: characters.length,
            itemBuilder: (_, i) {
              final c = characters[i];
              return Card(
                color: NoraColors.surface,
                child: Column(
                  children: [
                    Expanded(
                      child: ClipRRect(
                        borderRadius: const BorderRadius.vertical(
                            top: Radius.circular(12)),
                        child: c.portraitUrl != null
                            ? CachedNetworkImage(
                                imageUrl: c.portraitUrl!,
                                fit: BoxFit.cover,
                                width: double.infinity)
                            : const ColoredBox(
                                color: NoraColors.bg,
                                child: Icon(Icons.person, size: 48)),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(8),
                      child: Column(
                        children: [
                          Text(c.displayName,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                  fontWeight: FontWeight.bold)),
                          Text(c.archetype,
                              style: const TextStyle(
                                  fontSize: 12,
                                  color: NoraColors.secondary)),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
    );
  }
}
