import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/battlechit_cta.dart';
import '../providers/matchmaking_providers.dart';
import '../providers/spectate_providers.dart';

/// The web Battle page under the crossplay structure (NORA_PLATFORMS_CROSSPLAY_
/// SPEC.md): mint BattleChits, FIND A MATCH in the shared web+Arena queue, play
/// right here, and SPECTATE live matches from either platform.
class BattleHubScreen extends ConsumerWidget {
  const BattleHubScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final matchesAsync = ref.watch(liveCcgMatchesProvider);
    final activeMatch = ref.watch(myActiveCcgMatchProvider).valueOrNull;

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        title: const Text('Battle', style: TextStyle(color: Colors.white)),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                // ── Resume a live match you're seated in ───────────────────
                if (activeMatch != null) ...[
                  InkWell(
                    onTap: () => context.push('/battle/play/$activeMatch'),
                    borderRadius: BorderRadius.circular(16),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(16),
                        color: AppTheme.success.withValues(alpha: 0.10),
                        border: Border.all(color: AppTheme.success),
                      ),
                      child: const Row(children: [
                        Icon(Icons.play_circle_fill,
                            color: AppTheme.success, size: 26),
                        SizedBox(width: 10),
                        Expanded(
                          child: Text('You have a match in progress — tap to resume',
                              style: TextStyle(
                                  color: AppTheme.textPrimary,
                                  fontSize: 14,
                                  fontWeight: FontWeight.w700)),
                        ),
                        Icon(Icons.chevron_right, color: AppTheme.success),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                // ── Find a match (crossplay: one queue, web + Arena app) ───
                InkWell(
                  onTap: () => context.push('/battle/find'),
                  borderRadius: BorderRadius.circular(16),
                  child: Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(16),
                      gradient: const LinearGradient(
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                        colors: [Color(0xFF1A1050), Color(0xFF0D2A24)],
                      ),
                      border: Border.all(color: AppTheme.primary, width: 1.5),
                    ),
                    child: const Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(Icons.sports_kabaddi,
                              color: AppTheme.secondary, size: 22),
                          SizedBox(width: 8),
                          Expanded(
                            child: Text('Find a match',
                                style: TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontSize: 17,
                                    fontWeight: FontWeight.w800)),
                          ),
                          Icon(Icons.chevron_right, color: AppTheme.primary),
                        ]),
                        SizedBox(height: 8),
                        Text(
                          'One queue across web and the NORA Arena app: bring a '
                          '20-card deck of your BattleChits and battle whoever is '
                          'up next — they might be on their phone, you\'re right '
                          'here in the browser.',
                          style: TextStyle(
                              color: AppTheme.textSecondary,
                              fontSize: 13,
                              height: 1.5),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                const BattleChitBanner(compact: true),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: () => context.push('/decks'),
                  icon: const Icon(Icons.dashboard_customize_outlined),
                  label: const Text('My Decks'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => context.push('/collection'),
                  icon: const Icon(Icons.style_outlined),
                  label: const Text('My BattleChits'),
                ),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                  onPressed: () => context.push('/market'),
                  icon: const Icon(Icons.storefront_outlined),
                  label: const Text('Chit Market'),
                ),
                const SizedBox(height: 24),

                // ── Live matches (spectate) ────────────────────────────────
                const Row(children: [
                  Icon(Icons.radio, color: AppTheme.danger, size: 18),
                  SizedBox(width: 6),
                  Text('Live Matches',
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w700)),
                  SizedBox(width: 8),
                  Text('Web + Arena app, live now',
                      style:
                          TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
                ]),
                const SizedBox(height: 12),
                matchesAsync.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.symmetric(vertical: 32),
                    child: Center(
                        child:
                            CircularProgressIndicator(color: AppTheme.primary)),
                  ),
                  error: (e, _) => Padding(
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    child: Text('Could not load live matches: $e',
                        style: const TextStyle(
                            color: AppTheme.danger, fontSize: 13)),
                  ),
                  data: (matches) => matches.isEmpty
                      ? const _NoLiveMatches()
                      : Column(
                          children: matches
                              .map((m) => _LiveMatchTile(match: m))
                              .toList()),
                ),

              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _NoLiveMatches extends StatelessWidget {
  const _NoLiveMatches();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 36),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: const Column(children: [
        Icon(Icons.sports_esports_outlined,
            size: 40, color: AppTheme.textSecondary),
        SizedBox(height: 12),
        Text('No live matches right now',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600)),
        SizedBox(height: 4),
        Text('When players battle — on web or in the NORA Arena app —\ntheir matches appear here in real time.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
      ]),
    );
  }
}

class _LiveMatchTile extends ConsumerWidget {
  final CcgLiveMatch match;
  const _LiveMatchTile({required this.match});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seatsAsync = ref.watch(ccgSeatsStreamProvider(match.id));
    final seats = seatsAsync.valueOrNull ?? [];
    final p1 = seats.where((s) => s.seat == 1).firstOrNull;
    final p2 = seats.where((s) => s.seat == 2).firstOrNull;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: InkWell(
        onTap: () => context.push('/battle/spectate/${match.id}'),
        borderRadius: BorderRadius.circular(14),
        child: Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: AppTheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
                color: AppTheme.danger.withValues(alpha: 0.45)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: AppTheme.danger.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: AppTheme.danger.withValues(alpha: 0.5)),
                  ),
                  child: const Text('● LIVE',
                      style: TextStyle(
                          color: AppTheme.danger,
                          fontSize: 10,
                          fontWeight: FontWeight.w800)),
                ),
                const SizedBox(width: 8),
                Text('Turn ${match.turnNumber}',
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 12)),
                const Spacer(),
                if (match.isMonetized)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppTheme.success.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                          color: AppTheme.success.withValues(alpha: 0.5)),
                    ),
                    child: const Text('USD MARKET',
                        style: TextStyle(
                            color: AppTheme.success,
                            fontSize: 9,
                            fontWeight: FontWeight.w800)),
                  ),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                    child: _SeatSummary(seat: p1, fallback: 'Player 1')),
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 10),
                  child: Text('VS',
                      style: TextStyle(
                          color: AppTheme.primary,
                          fontSize: 14,
                          fontWeight: FontWeight.w900)),
                ),
                Expanded(
                    child: _SeatSummary(
                        seat: p2, fallback: 'Player 2', alignEnd: true)),
              ]),
            ],
          ),
        ),
      ),
    );
  }
}

class _SeatSummary extends StatelessWidget {
  final CcgSeat? seat;
  final String fallback;
  final bool alignEnd;
  const _SeatSummary(
      {required this.seat, required this.fallback, this.alignEnd = false});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment:
          alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
      children: [
        Text(seat?.username ?? fallback,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 14,
                fontWeight: FontWeight.w700)),
        const SizedBox(height: 2),
        Text('❤ ${seat?.life ?? '—'}',
            style: const TextStyle(color: AppTheme.danger, fontSize: 13)),
      ],
    );
  }
}
