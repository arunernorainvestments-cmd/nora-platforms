import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/config/theme.dart';
import '../../../core/models/unlocked_character.dart';
import '../providers/license_sync_providers.dart';

/// "Your Licensed Characters" — the import screen (doc6). Tapping Sync re-runs
/// verification against the N.O.R.A. API and lists the unlocked fighters.
class LicenseSyncScreen extends ConsumerWidget {
  const LicenseSyncScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(unlockedCharactersProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Your Licensed Characters')),
      body: RefreshIndicator(
        onRefresh: () async => ref.invalidate(unlockedCharactersProvider),
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            FilledButton.icon(
              icon: const Icon(Icons.sync),
              label: const Text('Sync with N.O.R.A. Platforms'),
              onPressed: () => ref.invalidate(unlockedCharactersProvider),
            ),
            const SizedBox(height: 16),
            async.when(
              loading: () => const Padding(
                padding: EdgeInsets.symmetric(vertical: 48),
                child: Center(child: CircularProgressIndicator()),
              ),
              error: (e, _) => _Message(
                icon: Icons.cloud_off,
                text: 'Could not reach the licensing service. Pull to retry.',
              ),
              data: (characters) => characters.isEmpty
                  ? const _Message(
                      icon: Icons.theater_comedy_outlined,
                      text:
                          'No licensed characters yet.\nBuy a likeness on N.O.R.A. Platforms, then tap Sync.',
                    )
                  : Column(
                      children: characters
                          .map((c) => _CharacterTile(character: c))
                          .toList(),
                    ),
            ),
            const SizedBox(height: 24),
            TextButton.icon(
              icon: const Icon(Icons.open_in_new),
              label: const Text('Browse more on N.O.R.A. Platforms'),
              onPressed: () => launchUrl(
                Uri.parse('https://noraplatforms.com/licenses'),
                mode: LaunchMode.externalApplication,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CharacterTile extends StatelessWidget {
  const _CharacterTile({required this.character});
  final UnlockedCharacter character;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: NoraColors.surface,
      child: ListTile(
        leading: CircleAvatar(
          radius: 26,
          backgroundColor: NoraColors.bg,
          backgroundImage: character.portraitUrl != null
              ? CachedNetworkImageProvider(character.portraitUrl!)
              : null,
          child: character.portraitUrl == null
              ? const Icon(Icons.person, color: NoraColors.primary)
              : null,
        ),
        title: Text(character.displayName),
        subtitle: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('License: ${character.licenseId}',
                style: const TextStyle(fontSize: 12)),
            if (character.expiryLabel != null)
              Text(character.expiryLabel!,
                  style: const TextStyle(fontSize: 12)),
            Text('Archetype: ${character.archetype}',
                style: const TextStyle(
                    fontSize: 12, color: NoraColors.secondary)),
          ],
        ),
        trailing: const Icon(Icons.chevron_right),
        onTap: () {
          // TODO(battle phase): push into character preview / set as combatant.
        },
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 40),
        child: Column(
          children: [
            Icon(icon, size: 40, color: Colors.white38),
            const SizedBox(height: 12),
            Text(text, textAlign: TextAlign.center),
          ],
        ),
      );
}
