import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/battlechit_cta.dart';
import '../../../core/widgets/n_back_button.dart';
import '../../auth/providers/auth_provider.dart';
import '../../battle/providers/matchmaking_providers.dart';
import '../../battle/providers/spectate_providers.dart';
import '../providers/arena_providers.dart';

/// The Arena — the front door to the Moments card-battler (v3). Everything here
/// is the ONE game: mint a BattleChit from a real moment, build a 20-card deck,
/// queue into the shared web + NORA Arena app pool, and spectate live matches.
/// The pre-v3 creator-vs-creator web arena survives at the bottom as a legacy
/// section until its P7 archival (its screens stay reachable — gated
/// retirement, RECONCILIATION R3).
class ArenaScreen extends ConsumerWidget {
  const ArenaScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final liveMatches = ref.watch(liveCcgMatchesProvider);
    final activeMatch = ref.watch(myActiveCcgMatchProvider).valueOrNull;
    final decks = ref.watch(myDecksProvider).valueOrNull ?? const [];
    final hasLegalDeck = decks.any((d) => d.isLegal);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: const NBackButton(fallback: '/battle'),
        title: const Text(
          'Arena',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontWeight: FontWeight.bold,
            fontSize: 20,
          ),
        ),
        backgroundColor: AppTheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1),
          child: Container(height: 1, color: AppTheme.cardBorder),
        ),
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 640),
            child: ListView(
              padding:
                  const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
              children: [
                const _HeroBlock(),
                const SizedBox(height: 24),

                // ── Resume a live match ────────────────────────────────────
                if (activeMatch != null) ...[
                  _ResumeBanner(matchId: activeMatch),
                  const SizedBox(height: 12),
                ],

                // ── Enter the Arena (crossplay queue) ──────────────────────
                _EnterArenaCard(hasLegalDeck: hasLegalDeck),
                const SizedBox(height: 12),

                // ── The three steps of the loop ────────────────────────────
                const _StepRow(
                  step: '1',
                  title: 'Mint a BattleChit',
                  subtitle:
                      'Turn a viral post you own into a playable card with '
                      'its own cutscene.',
                  icon: Icons.auto_awesome,
                  route: '/mint',
                ),
                const SizedBox(height: 8),
                const _StepRow(
                  step: '2',
                  title: 'Build your deck',
                  subtitle: '20 cards, max 2 copies each — creatures and '
                      'spell-moments.',
                  icon: Icons.dashboard_customize_outlined,
                  route: '/decks',
                ),
                const SizedBox(height: 8),
                const _StepRow(
                  step: '3',
                  title: 'Battle for the win',
                  subtitle: 'Spend Aura, summon your moments, bring the '
                      'opponent\'s 30 Life to zero.',
                  icon: Icons.sports_kabaddi,
                  route: '/battle/find',
                ),
                const SizedBox(height: 24),

                // ── Live matches (spectate) ────────────────────────────────
                const Row(children: [
                  Icon(Icons.radio, color: AppTheme.danger, size: 18),
                  SizedBox(width: 6),
                  Text('Live now',
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 17,
                          fontWeight: FontWeight.w700)),
                  SizedBox(width: 8),
                  Text('Web + NORA Arena app',
                      style: TextStyle(
                          color: AppTheme.textSecondary, fontSize: 12)),
                ]),
                const SizedBox(height: 12),
                liveMatches.when(
                  loading: () => const Padding(
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(
                        child: CircularProgressIndicator(
                            color: AppTheme.primary)),
                  ),
                  error: (e, _) => Text('Could not load live matches: $e',
                      style: const TextStyle(
                          color: AppTheme.danger, fontSize: 13)),
                  data: (matches) => matches.isEmpty
                      ? const _NoLiveMatches()
                      : Column(
                          children: matches
                              .map((m) => _LiveMatchTile(match: m))
                              .toList()),
                ),
                const SizedBox(height: 24),

                // ── Collection / market shortcuts ──────────────────────────
                Row(children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => context.push('/collection'),
                      icon: const Icon(Icons.style_outlined, size: 18),
                      label: const Text('Collection'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => context.push('/market'),
                      icon: const Icon(Icons.storefront_outlined, size: 18),
                      label: const Text('Chit Market'),
                    ),
                  ),
                ]),
                const SizedBox(height: 16),
                const _MobileAppBanner(),
                const SizedBox(height: 24),
                const _LegacyArenaSection(),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Hero ─────────────────────────────────────────────────────────────────────

class _HeroBlock extends StatelessWidget {
  const _HeroBlock();

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF241866), Color(0xFF0D2A3E)],
            ),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: AppTheme.primary.withValues(alpha: 0.5),
            ),
            boxShadow: [
              BoxShadow(
                color: AppTheme.primary.withValues(alpha: 0.3),
                blurRadius: 24,
              ),
            ],
          ),
          child: const Icon(
            Icons.local_fire_department_outlined,
            color: AppTheme.secondary,
            size: 36,
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Moments Arena',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 32,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Real viral moments, minted into cards, battled live.\n'
          'Summon your friend — your friend earns.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 15,
            height: 1.4,
          ),
        ),
      ],
    );
  }
}

// ─── Resume banner ────────────────────────────────────────────────────────────

class _ResumeBanner extends StatelessWidget {
  const _ResumeBanner({required this.matchId});

  final String matchId;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => context.push('/battle/play/$matchId'),
      borderRadius: BorderRadius.circular(16),
      child: Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(16),
          color: AppTheme.success.withValues(alpha: 0.10),
          border: Border.all(color: AppTheme.success),
        ),
        child: const Row(children: [
          Icon(Icons.play_circle_fill, color: AppTheme.success, size: 26),
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
    );
  }
}

// ─── Enter the Arena ──────────────────────────────────────────────────────────

class _EnterArenaCard extends StatelessWidget {
  const _EnterArenaCard({required this.hasLegalDeck});

  final bool hasLegalDeck;

  @override
  Widget build(BuildContext context) {
    return InkWell(
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
          boxShadow: [
            BoxShadow(
              color: AppTheme.primary.withValues(alpha: 0.25),
              blurRadius: 18,
            ),
          ],
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(children: [
              Icon(Icons.sports_kabaddi, color: AppTheme.secondary, size: 22),
              SizedBox(width: 8),
              Expanded(
                child: Text('Enter the Arena',
                    style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w800)),
              ),
              Icon(Icons.chevron_right, color: AppTheme.primary),
            ]),
            const SizedBox(height: 8),
            Text(
              hasLegalDeck
                  ? 'Your deck is battle-legal. One queue across web and the '
                      'NORA Arena app — whoever\'s next is your opponent.'
                  : 'One queue across web and the NORA Arena app. You\'ll '
                      'need a legal 20-card deck — build one in a minute, or '
                      'quick-build from your best cards.',
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 13, height: 1.5),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Loop steps ───────────────────────────────────────────────────────────────

class _StepRow extends StatelessWidget {
  const _StepRow({
    required this.step,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.route,
  });

  final String step;
  final String title;
  final String subtitle;
  final IconData icon;
  final String route;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => context.push(route),
      borderRadius: BorderRadius.circular(14),
      child: Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppTheme.primary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                  color: AppTheme.primary.withValues(alpha: 0.25)),
            ),
            child: Icon(icon, color: AppTheme.primary, size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Text('STEP $step',
                      style: TextStyle(
                          color:
                              AppTheme.secondary.withValues(alpha: 0.9),
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 1.2)),
                ]),
                const SizedBox(height: 2),
                Text(title,
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 2),
                Text(subtitle,
                    style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 12,
                        height: 1.4)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right,
              color: AppTheme.textSecondary, size: 20),
        ]),
      ),
    );
  }
}

// ─── Live matches ─────────────────────────────────────────────────────────────

class _NoLiveMatches extends StatelessWidget {
  const _NoLiveMatches();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 32),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: const Column(children: [
        Icon(Icons.sports_esports_outlined,
            size: 36, color: AppTheme.textSecondary),
        SizedBox(height: 10),
        Text('No live matches right now',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w600)),
        SizedBox(height: 4),
        Text(
            'When players battle — on web or in the NORA Arena app —\n'
            'their matches appear here in real time.',
            textAlign: TextAlign.center,
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12)),
      ]),
    );
  }
}

class _LiveMatchTile extends ConsumerWidget {
  const _LiveMatchTile({required this.match});

  final CcgLiveMatch match;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final seats = ref.watch(ccgSeatsStreamProvider(match.id)).valueOrNull ??
        const <CcgSeat>[];
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
            border:
                Border.all(color: AppTheme.danger.withValues(alpha: 0.45)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 3),
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
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
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
                Expanded(child: _SeatSummary(seat: p1, fallback: 'Player 1')),
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
  const _SeatSummary(
      {required this.seat, required this.fallback, this.alignEnd = false});

  final CcgSeat? seat;
  final String fallback;
  final bool alignEnd;

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

// ─── Mobile app banner ────────────────────────────────────────────────────────

class _MobileAppBanner extends StatelessWidget {
  const _MobileAppBanner();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(16),
        gradient: const LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF1A1050), Color(0xFF0D2A24)],
        ),
        border: Border.all(color: AppTheme.secondary, width: 1.5),
      ),
      child: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            Icon(Icons.smartphone, color: AppTheme.secondary, size: 20),
            SizedBox(width: 8),
            Expanded(
              child: Text('NORA Arena — the mobile app',
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w800)),
            ),
          ]),
          SizedBox(height: 8),
          Text(
            'The same battles in full 3D on your phone. One account, one '
            'collection, one queue — start a match here, spectate from '
            'anywhere.',
            style: TextStyle(
                color: AppTheme.textSecondary, fontSize: 13, height: 1.5),
          ),
          SizedBox(height: 14),
          BattleChitButton(label: 'Mint your first BattleChit →'),
        ],
      ),
    );
  }
}

// ─── Legacy creator arena (pre-v3) — kept reachable until P7 archival ─────────

class _LegacyArenaSection extends ConsumerWidget {
  const _LegacyArenaSection();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Container(
      decoration: BoxDecoration(
        color: AppTheme.surface.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: const ExpansionTile(
          leading: Icon(Icons.history,
              color: AppTheme.textSecondary, size: 20),
          title: Text('Creator Arena (legacy)',
              style: TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600)),
          subtitle: Text(
              'The pre-Moments creator-vs-creator format — still open while '
              'it winds down.',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 11)),
          childrenPadding: EdgeInsets.fromLTRB(16, 0, 16, 16),
          children: [
            _LegacyFindMatchButton(),
            SizedBox(height: 12),
            _LegacyRound3Readiness(),
          ],
        ),
      ),
    );
  }
}

class _LegacyFindMatchButton extends ConsumerWidget {
  const _LegacyFindMatchButton();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final matchState = ref.watch(matchmakingProvider);
    final isLoading = matchState.isLoading;

    return OutlinedButton.icon(
      onPressed: isLoading
          ? null
          : () async {
              final notifier = ref.read(matchmakingProvider.notifier);
              final matchId = await notifier.findMatch();
              if (!context.mounted) return;
              if (matchId != null) {
                context.push('/arena/$matchId');
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text(
                      'No legacy matches available right now.',
                      style: TextStyle(color: Colors.white),
                    ),
                    backgroundColor: Color(0xFF2A2A3E),
                  ),
                );
              }
            },
      icon: isLoading
          ? const SizedBox(
              width: 14,
              height: 14,
              child: CircularProgressIndicator(strokeWidth: 2),
            )
          : const Icon(Icons.play_arrow_rounded, size: 18),
      label: Text(isLoading ? 'Finding match…' : 'Find a creator match'),
    );
  }
}

class _LegacyRound3Readiness extends ConsumerWidget {
  const _LegacyRound3Readiness();

  DateTime _nextFriday7PM() {
    final now = DateTime.now().toUtc();
    final daysUntilFriday = (5 - now.weekday + 7) % 7; // weekday 1=Mon, 5=Fri
    var friday =
        DateTime.utc(now.year, now.month, now.day + daysUntilFriday, 19, 0, 0);
    if (friday.isBefore(now)) friday = friday.add(const Duration(days: 7));
    return friday;
  }

  String _fmtCountdown(Duration d) {
    if (d.isNegative) return 'Now';
    final days = d.inDays;
    final hours = d.inHours % 24;
    final mins = d.inMinutes % 60;
    if (days > 0) return '${days}d ${hours}h';
    if (hours > 0) return '${hours}h ${mins}m';
    return '${mins}m';
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(currentUserProvider);
    if (user == null) return const SizedBox.shrink();

    final myPoints = ref.watch(arenaWeeklyPointsProvider).valueOrNull ?? 0;
    final topPlayers =
        ref.watch(arenaTopWeeklyPlayersProvider).valueOrNull ?? [];
    final bracket = ref.watch(arenaCurrentBracketProvider).valueOrNull;

    final isQualified = topPlayers.contains(user.id);
    final bracketState = bracket?['state'] as String?;
    final timeToFriday =
        _nextFriday7PM().difference(DateTime.now().toUtc());

    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: const Color(0xFFFFD700).withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: const Color(0xFFFFD700).withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(Icons.emoji_events_outlined,
                color: Color(0xFFFFD700), size: 20),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Text('Champions Bracket',
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w700)),
                  const Spacer(),
                  if (isQualified)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color:
                            const Color(0xFFFFD700).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text('Qualified',
                          style: TextStyle(
                              color: Color(0xFFFFD700),
                              fontSize: 10,
                              fontWeight: FontWeight.w700)),
                    ),
                ]),
                const SizedBox(height: 4),
                if (bracketState == 'active' || bracketState == 'completed')
                  Text(
                    bracketState == 'completed'
                        ? 'Bracket complete — results Monday'
                        : 'Bracket active — Round ${bracket?['current_round']}',
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 12),
                  )
                else
                  Row(children: [
                    const Text(
                      'Friday 7 PM UTC: ',
                      style: TextStyle(
                          color: AppTheme.textSecondary, fontSize: 12),
                    ),
                    Text(
                      _fmtCountdown(timeToFriday),
                      style: const TextStyle(
                          color: Color(0xFFFFD700),
                          fontSize: 12,
                          fontWeight: FontWeight.w700),
                    ),
                  ]),
                if (myPoints > 0) ...[
                  const SizedBox(height: 3),
                  Text('Your points this week: $myPoints',
                      style: const TextStyle(
                          color: AppTheme.textSecondary, fontSize: 12)),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
