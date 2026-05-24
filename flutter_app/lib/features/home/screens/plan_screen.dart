import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';

class PlanScreen extends StatelessWidget {
  const PlanScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: AppTheme.background,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            backgroundColor: AppTheme.surface,
            pinned: true,
            title: const Text('Phase 2'),
            actions: [
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.secondary.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                        color: AppTheme.secondary.withValues(alpha: 0.4)),
                  ),
                  child: const Text('SIM MODE LIVE',
                      style: TextStyle(
                          color: AppTheme.secondary,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.8)),
                ),
              ),
            ],
          ),
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Hero(),
                _HowItWorks(),
                _FeaturesGrid(),
                _RegulatorySection(),
                _SimulationSection(onExplore: () => context.push('/campaigns')),
                _Phase3Teaser(),
                const SizedBox(height: 48),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Hero ─────────────────────────────────────────────────────────────────────

class _Hero extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 40),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            AppTheme.primary.withValues(alpha: 0.18),
            AppTheme.secondary.withValues(alpha: 0.08),
            AppTheme.background,
          ],
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding:
                const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
            decoration: BoxDecoration(
              color: AppTheme.danger.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
              border:
                  Border.all(color: AppTheme.danger.withValues(alpha: 0.4)),
            ),
            child: const Text('PENDING REGULATORY APPROVAL',
                style: TextStyle(
                    color: AppTheme.danger,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1)),
          ),
          const SizedBox(height: 20),
          const Text(
            'NORA Campaigns',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 32,
                fontWeight: FontWeight.w900,
                height: 1.1),
          ),
          const SizedBox(height: 4),
          ShaderMask(
            shaderCallback: (bounds) => const LinearGradient(
              colors: [AppTheme.primary, AppTheme.secondary],
            ).createShader(bounds),
            child: const Text(
              'Royalty Crowdfunding',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Creators launch funding campaigns. Backers invest in '
            'a percentage of future royalties. Real returns tied to '
            'real revenue — enforced mechanically, not by trust.',
            style: TextStyle(
                color: AppTheme.textSecondary, fontSize: 15, height: 1.6),
          ),
          const SizedBox(height: 28),
          const Row(children: [
            _Pill(
              icon: Icons.shield_outlined,
              label: 'SEC Reg CF',
              color: AppTheme.primary,
            ),
            SizedBox(width: 10),
            _Pill(
              icon: Icons.link,
              label: 'On-Chain Ready',
              color: AppTheme.secondary,
            ),
            SizedBox(width: 10),
            _Pill(
              icon: Icons.science_outlined,
              label: 'Sim Mode Live',
              color: AppTheme.success,
            ),
          ]),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;
  const _Pill({required this.icon, required this.label, required this.color});

  @override
  Widget build(BuildContext context) => Container(
        padding:
            const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: color.withValues(alpha: 0.3)),
        ),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 5),
          Text(label,
              style: TextStyle(
                  color: color,
                  fontSize: 11,
                  fontWeight: FontWeight.w600)),
        ]),
      );
}

// ─── How It Works ─────────────────────────────────────────────────────────────

class _HowItWorks extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel('HOW IT WORKS'),
          const SizedBox(height: 20),
          const _Step(
            number: '01',
            title: 'Creator launches a campaign',
            body: 'A creator sets a funding goal and offers a percentage '
                'of future royalties — from an album, film, podcast, software, '
                'or any creative work. The platform files an SEC Form C before '
                'any investment can occur.',
            color: AppTheme.primary,
          ),
          _connector(),
          const _Step(
            number: '02',
            title: 'Backers invest',
            body: 'Anyone can invest within their Reg CF limits. Each dollar '
                'buys a proportional royalty stake, recorded in an immutable '
                'ownership ledger designed to migrate on-chain when the NORA '
                'coin launches.',
            color: AppTheme.secondary,
          ),
          _connector(),
          const _Step(
            number: '03',
            title: 'Revenue flows to backers',
            body: 'As the creator earns — from streams, views, downloads, '
                'or sales — the platform verifies the revenue and automatically '
                'distributes royalty payments to all backers in proportion '
                'to their stake. No creator intervention required.',
            color: AppTheme.success,
          ),
        ],
      ),
    );
  }

  Widget _connector() => Padding(
        padding: const EdgeInsets.only(left: 24),
        child: Container(
          width: 2,
          height: 28,
          color: AppTheme.cardBorder,
        ),
      );
}

class _Step extends StatelessWidget {
  final String number;
  final String title;
  final String body;
  final Color color;

  const _Step({
    required this.number,
    required this.title,
    required this.body,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              shape: BoxShape.circle,
              border: Border.all(color: color.withValues(alpha: 0.4)),
            ),
            child: Center(
              child: Text(number,
                  style: TextStyle(
                      color: color,
                      fontSize: 13,
                      fontWeight: FontWeight.w800)),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: const TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700)),
                  const SizedBox(height: 6),
                  Text(body,
                      style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 13,
                          height: 1.6)),
                ],
              ),
            ),
          ),
        ],
      );
}

// ─── Features Grid ────────────────────────────────────────────────────────────

class _FeaturesGrid extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(24, 40, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionLabel('WHAT YOU GET'),
          SizedBox(height: 20),
          _FeatureCard(
            icon: Icons.pie_chart_outline,
            color: AppTheme.primary,
            title: 'Royalty Ownership',
            body: 'Your investment buys a real percentage of a creator\'s '
                'revenue stream. Not a donation. Not a gift. An investment '
                'with verifiable returns.',
          ),
          SizedBox(height: 12),
          _FeatureCard(
            icon: Icons.how_to_vote_outlined,
            color: AppTheme.secondary,
            title: 'Creator Governance',
            body: 'Backers vote on how escrowed capital is spent. '
                'Simple majority with a 25% quorum threshold. '
                'Proposals, votes, and fund releases are all auditable.',
          ),
          SizedBox(height: 12),
          _FeatureCard(
            icon: Icons.swap_horiz,
            color: AppTheme.success,
            title: 'Secondary Market',
            body: 'List your royalty stake for sale at any time once '
                'a campaign is active. Buyers get the exact stake you held — '
                'every transfer recorded in the ownership ledger.',
          ),
          SizedBox(height: 12),
          _FeatureCard(
            icon: Icons.link,
            color: Color(0xFFFFD700),
            title: 'On-Chain Future',
            body: 'The ownership ledger is append-only and designed to '
                'mirror blockchain state. When the NORA coin launches, '
                'every stake becomes a token. No migration work required for backers.',
          ),
          SizedBox(height: 12),
          _FeatureCard(
            icon: Icons.verified_outlined,
            color: AppTheme.primary,
            title: 'Verified Revenue',
            body: 'Revenue starts with creator uploads. The roadmap adds '
                'CSV imports, Spotify and YouTube OAuth pulls, and eventually '
                'direct data partnerships — so payouts require zero creator '
                'manual input.',
          ),
        ],
      ),
    );
  }
}

class _FeatureCard extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String title;
  final String body;

  const _FeatureCard({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
  });

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: color.withValues(alpha: 0.2)),
        ),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, color: color, size: 22),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w700)),
                const SizedBox(height: 5),
                Text(body,
                    style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 13,
                        height: 1.5)),
              ],
            ),
          ),
        ]),
      );
}

// ─── Regulatory Section ───────────────────────────────────────────────────────

class _RegulatorySection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel('WHY IT\'S NOT LIVE YET'),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: AppTheme.danger.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.danger.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.gavel_outlined,
                        color: AppTheme.danger, size: 20),
                  ),
                  const SizedBox(width: 12),
                  const Text('Regulation Crowdfunding (Reg CF)',
                      style: TextStyle(
                          color: AppTheme.textPrimary,
                          fontSize: 15,
                          fontWeight: FontWeight.w700)),
                ]),
                const SizedBox(height: 16),
                const Text(
                  'Campaigns are securities offerings under the JOBS Act. '
                  'Going live requires:',
                  style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 13,
                      height: 1.6),
                ),
                const SizedBox(height: 14),
                ...[
                  (
                    'SEC Funding Portal Registration',
                    'NORA must register as a Funding Portal (Form Funding Portal) '
                        'with the SEC before any campaign can go live.'
                  ),
                  (
                    'Form C per campaign',
                    'Each creator campaign requires an individual SEC Form C '
                        'filing before accepting investments.'
                  ),
                  (
                    'Annual raise limits',
                    'Creators can raise up to \$5M per year under Reg CF. '
                        'US investors have per-year investment limits based on income.'
                  ),
                  (
                    'Attorney review',
                    'Legal counsel must review each campaign before '
                        'it opens to investors.'
                  ),
                ].map((item) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(top: 5),
                            child: Icon(Icons.circle,
                                size: 5, color: AppTheme.danger),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(item.$1,
                                    style: const TextStyle(
                                        color: AppTheme.textPrimary,
                                        fontSize: 13,
                                        fontWeight: FontWeight.w600)),
                                const SizedBox(height: 2),
                                Text(item.$2,
                                    style: const TextStyle(
                                        color: AppTheme.textSecondary,
                                        fontSize: 12,
                                        height: 1.5)),
                              ],
                            ),
                          ),
                        ],
                      ),
                    )),
              ],
            ),
          ),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.success.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                  color: AppTheme.success.withValues(alpha: 0.25)),
            ),
            child: const Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.check_circle_outline,
                    color: AppTheme.success, size: 18),
                SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'The platform is fully built and compliance-ready. '
                    'The moment regulatory approval is in hand, we flip the '
                    'switch — no code change, just a database update.',
                    style: TextStyle(
                        color: AppTheme.success,
                        fontSize: 13,
                        height: 1.5),
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

// ─── Simulation Section ───────────────────────────────────────────────────────

class _SimulationSection extends StatelessWidget {
  final VoidCallback onExplore;
  const _SimulationSection({required this.onExplore});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel('TRY IT TODAY'),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [
                  AppTheme.secondary.withValues(alpha: 0.12),
                  AppTheme.primary.withValues(alpha: 0.06),
                ],
              ),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: AppTheme.secondary.withValues(alpha: 0.35)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Icon(Icons.science_outlined,
                      color: AppTheme.secondary, size: 22),
                  const SizedBox(width: 10),
                  const Text('Simulation Mode',
                      style: TextStyle(
                          color: AppTheme.secondary,
                          fontSize: 16,
                          fontWeight: FontWeight.w800)),
                  const Spacer(),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: AppTheme.success.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: const Text('LIVE NOW',
                        style: TextStyle(
                            color: AppTheme.success,
                            fontSize: 9,
                            fontWeight: FontWeight.w800,
                            letterSpacing: 1)),
                  ),
                ]),
                const SizedBox(height: 14),
                const Text(
                  'The entire platform — campaigns, investing, governance, '
                  'distributions, and the secondary market — is running '
                  'right now in simulation mode.',
                  style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 13,
                      height: 1.6),
                ),
                const SizedBox(height: 12),
                ...[
                  'Start with \$10,000 in simulated USD — seeded automatically',
                  'Browse and invest in real simulated campaigns',
                  'Earn simulated royalty distributions as revenue events are posted',
                  'Vote on governance proposals (Phase 3)',
                  'Trade stakes on the secondary market (Phase 4)',
                ].map((item) => Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(top: 5),
                            child: Icon(Icons.arrow_forward_ios,
                                size: 9, color: AppTheme.secondary),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(item,
                                style: const TextStyle(
                                    color: AppTheme.textPrimary,
                                    fontSize: 13,
                                    height: 1.5)),
                          ),
                        ],
                      ),
                    )),
                const SizedBox(height: 20),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: onExplore,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.secondary,
                      foregroundColor: Colors.black,
                      padding:
                          const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text('Explore Campaigns in Simulation',
                        style: TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 14)),
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

// ─── Phase 3 Teaser ───────────────────────────────────────────────────────────

class _Phase3Teaser extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel('WHAT\'S AFTER PHASE 2'),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.cardBorder),
            ),
            child: const Column(children: [
              _Phase3Item(
                icon: Icons.how_to_vote_outlined,
                title: 'Governance (Phase 3)',
                body: 'Backers vote on creator spending proposals. '
                    'Approved votes release escrowed capital directly.',
                color: AppTheme.primary,
              ),
              Divider(color: AppTheme.cardBorder, height: 28),
              _Phase3Item(
                icon: Icons.swap_horiz,
                title: 'Secondary Market (Phase 4)',
                body: 'Buy and sell royalty stakes between users. '
                    'Listing + buy-now model to start, order book post-launch.',
                color: AppTheme.secondary,
              ),
              Divider(color: AppTheme.cardBorder, height: 28),
              _Phase3Item(
                icon: Icons.hub_outlined,
                title: 'Revenue API Integrations (Phase 6)',
                body: 'YouTube, Spotify, DistroKid, and TuneCore pull '
                    'revenue data automatically. Zero creator manual input.',
                color: AppTheme.success,
              ),
              Divider(color: AppTheme.cardBorder, height: 28),
              _Phase3Item(
                icon: Icons.currency_bitcoin,
                title: 'On-Chain Settlement (Phase 7)',
                body: 'Every campaign stake becomes a NORA coin token. '
                    'Distributions settle on-chain. '
                    'No migration work for existing backers.',
                color: Color(0xFFFFD700),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

class _Phase3Item extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final Color color;

  const _Phase3Item({
    required this.icon,
    required this.title,
    required this.body,
    required this.color,
  });

  @override
  Widget build(BuildContext context) => Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color, size: 20),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
                const SizedBox(height: 4),
                Text(body,
                    style: const TextStyle(
                        color: AppTheme.textSecondary,
                        fontSize: 13,
                        height: 1.5)),
              ],
            ),
          ),
        ],
      );
}

// ─── Shared helpers ───────────────────────────────────────────────────────────

class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) => Text(
        text,
        style: TextStyle(
            color: AppTheme.textSecondary.withValues(alpha: 0.7),
            fontSize: 11,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.4),
      );
}
