import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/arena_providers.dart';

class ArenaScreen extends ConsumerWidget {
  const ArenaScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
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
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 28),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _HeroBlock(),
              const SizedBox(height: 20),
              _FindMatchButton(),
              const SizedBox(height: 28),
              const _SectionLabel('ROUNDS'),
              const SizedBox(height: 12),
              const _RoundCard(
                round: 1,
                name: 'Discovery',
                schedule: '7 AM – 7 PM daily',
                matchDuration: '1 hour per match',
                matchType: 'Same category',
                pointsPerWin: 1,
                accentColor: AppTheme.secondary,
                icon: Icons.explore_outlined,
              ),
              const SizedBox(height: 12),
              const _RoundCard(
                round: 2,
                name: 'Chaos',
                schedule: '7 PM – 7 AM daily',
                matchDuration: '30 min per match',
                matchType: 'Cross-category',
                pointsPerWin: 2,
                accentColor: Color(0xFFFF6B35),
                icon: Icons.bolt_outlined,
              ),
              const SizedBox(height: 12),
              const _RoundCard(
                round: 3,
                name: 'Champions',
                schedule: 'Friday 7 PM → Sunday midnight',
                matchDuration: '5 min per match',
                matchType: 'Weekly top performers',
                pointsPerWin: 5,
                accentColor: Color(0xFFFFD700),
                icon: Icons.emoji_events_outlined,
              ),
              const SizedBox(height: 32),
              const _AudienceCallout(),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Hero block ───────────────────────────────────────────────────────────────

class _HeroBlock extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: AppTheme.primary.withValues(alpha: 0.3),
            ),
          ),
          child: const Icon(
            Icons.shield_outlined,
            color: AppTheme.primary,
            size: 36,
          ),
        ),
        const SizedBox(height: 16),
        const Text(
          'Arena',
          style: TextStyle(
            color: AppTheme.textPrimary,
            fontSize: 32,
            fontWeight: FontWeight.w800,
            letterSpacing: -0.5,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Compete, back creators, and win tokens.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: AppTheme.textSecondary,
            fontSize: 15,
          ),
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: AppTheme.primary.withValues(alpha: 0.1),
            border: Border.all(color: AppTheme.primary.withValues(alpha: 0.35)),
            borderRadius: BorderRadius.circular(999),
          ),
          child: const Text(
            'Phase B Live',
            style: TextStyle(
              color: AppTheme.primary,
              fontSize: 11,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.5,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Section label ────────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        color: AppTheme.textSecondary.withValues(alpha: 0.6),
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.2,
      ),
    );
  }
}

// ─── Round card ───────────────────────────────────────────────────────────────

class _RoundCard extends StatelessWidget {
  final int round;
  final String name;
  final String schedule;
  final String matchDuration;
  final String matchType;
  final int pointsPerWin;
  final Color accentColor;
  final IconData icon;

  const _RoundCard({
    required this.round,
    required this.name,
    required this.schedule,
    required this.matchDuration,
    required this.matchType,
    required this.pointsPerWin,
    required this.accentColor,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Round icon
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: accentColor.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: accentColor.withValues(alpha: 0.25)),
            ),
            child: Icon(icon, color: accentColor, size: 20),
          ),
          const SizedBox(width: 14),
          // Details
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 1),
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'Round $round',
                        style: TextStyle(
                          color: accentColor,
                          fontSize: 9,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.5,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      name,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                _DetailRow(Icons.schedule_outlined, schedule),
                const SizedBox(height: 3),
                _DetailRow(Icons.timer_outlined, matchDuration),
                const SizedBox(height: 3),
                _DetailRow(Icons.swap_horiz_outlined, matchType),
              ],
            ),
          ),
          // Points badge
          Column(
            children: [
              Text(
                '+$pointsPerWin',
                style: TextStyle(
                  color: accentColor,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
              Text(
                'pt${pointsPerWin > 1 ? 's' : ''}/win',
                style: const TextStyle(
                  color: AppTheme.textSecondary,
                  fontSize: 10,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DetailRow extends StatelessWidget {
  final IconData icon;
  final String text;
  const _DetailRow(this.icon, this.text);

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 12, color: AppTheme.textSecondary),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            text,
            style: const TextStyle(
              color: AppTheme.textSecondary,
              fontSize: 12,
            ),
          ),
        ),
      ],
    );
  }
}

// ─── Find a Match button ──────────────────────────────────────────────────────

class _FindMatchButton extends ConsumerWidget {
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final matchState = ref.watch(matchmakingProvider);
    final isLoading = matchState.isLoading;

    return FilledButton.icon(
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
                      'No matches available right now — try again in a moment.',
                    ),
                    backgroundColor: AppTheme.surface,
                  ),
                );
              }
            },
      icon: isLoading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: AppTheme.textPrimary,
              ),
            )
          : const Icon(Icons.play_arrow_rounded),
      label: Text(isLoading ? 'Finding match…' : 'Find a Match'),
      style: FilledButton.styleFrom(
        backgroundColor: AppTheme.primary,
        foregroundColor: AppTheme.textPrimary,
        padding: const EdgeInsets.symmetric(vertical: 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        textStyle: const TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

// ─── Audience callout ─────────────────────────────────────────────────────────

class _AudienceCallout extends StatelessWidget {
  const _AudienceCallout();

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: AppTheme.secondary.withValues(alpha: 0.3),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              color: AppTheme.secondary.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.groups_outlined,
              color: AppTheme.secondary,
              size: 20,
            ),
          ),
          const SizedBox(width: 14),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Audience participation',
                  style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                SizedBox(height: 3),
                Text(
                  'Back creators with tokens, trigger power-ups, and shift momentum mid-match.',
                  style: TextStyle(
                    color: AppTheme.textSecondary,
                    fontSize: 12,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
