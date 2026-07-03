import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';

// /plan — the public "How N.O.R.A. works" explainer.
// Covers the Moments card game (minting, consent & likeness, how cards work),
// the two prediction-market loops, and what's live today vs coming at launch.
//
// Compliance note (CLAUDE.md governance): cards are collectible game assets.
// Never describe them with investment/return/yield/dividend/revenue-share
// language.
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
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () =>
                  context.canPop() ? context.pop() : context.go('/home'),
            ),
            title: const Text('How N.O.R.A. Works'),
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
                  child: const Text('BETA',
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
                _CardsExplainer(),
                _ConsentSection(),
                _MarketsExplainer(),
                _StatusSection(),
                _CommunityTeaser(),
                _GetStartedCta(),
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
              color: AppTheme.secondary.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                  color: AppTheme.secondary.withValues(alpha: 0.4)),
            ),
            child: const Text('LAUNCHING JULY 4, 2026',
                style: TextStyle(
                    color: AppTheme.secondary,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 1)),
          ),
          const SizedBox(height: 20),
          const Text(
            'Moments',
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
              'The viral-moment card game',
              style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(height: 20),
          const Text(
            'Every viral post is a moment. On N.O.R.A. you can mint a moment '
            'you own into a playable collectible card, build a deck, and '
            'battle other players — while the community predicts which '
            'creators are about to blow up.',
            style: TextStyle(
                color: AppTheme.textSecondary, fontSize: 15, height: 1.6),
          ),
          const SizedBox(height: 28),
          const Row(children: [
            _Pill(
              icon: Icons.style_outlined,
              label: 'Collectible Cards',
              color: AppTheme.primary,
            ),
            SizedBox(width: 10),
            _Pill(
              icon: Icons.verified_user_outlined,
              label: 'Consent-First',
              color: AppTheme.secondary,
            ),
            SizedBox(width: 10),
            _Pill(
              icon: Icons.trending_up,
              label: 'Creator Markets',
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
            title: 'Create your account',
            body: 'Sign up with your email and set up your profile. '
                'Optionally link the social accounts you own — TikTok, '
                'Instagram, or YouTube. Linking is always your choice, and '
                'it\'s what unlocks minting.',
            color: AppTheme.primary,
          ),
          _connector(),
          const _Step(
            number: '02',
            title: 'Mint a moment card',
            body: 'Pick a viral post you own and mint it into a playable '
                'card. The moment\'s engagement decides the card\'s tier '
                '(F up to S) — the stats and cost are derived from the tier, '
                'never hand-picked. Every mint passes content moderation and '
                'you preview the card in a practice battle before it\'s final.',
            color: AppTheme.secondary,
          ),
          _connector(),
          const _Step(
            number: '03',
            title: 'Build a deck & battle',
            body: 'Decks are 20 cards, max two copies each. Summon creatures '
                'and cast spell-moments using Aura, which grows every turn. '
                'Reduce your opponent\'s Life to zero to win. All combat is '
                'resolved server-side — no pay-to-win client tricks.',
            color: AppTheme.success,
          ),
          _connector(),
          const _Step(
            number: '04',
            title: 'Predict the rise of creators',
            body: 'Independently of the card game, bet platform tokens on '
                'whether a creator\'s Display Score goes up or down. When a '
                'market resolves, 90% of the pool goes to winning bettors, '
                '5% to the platform, and 5% to the creator (the Market Maker).',
            color: Color(0xFFFFD700),
          ),
          _connector(),
          const _Step(
            number: '05',
            title: 'Go pro as a Market Maker',
            body: 'Opting in as a Market Maker means consenting to markets on '
                'your popularity and to the platform using your linked-account '
                'likeness for those markets and your minted cards. It requires '
                'identity verification (KYC), and in return you earn the '
                'creator\'s share whenever your markets resolve or your '
                'moments appear in monetized matches.',
            color: AppTheme.danger,
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

// ─── How the cards work ───────────────────────────────────────────────────────

class _CardsExplainer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.fromLTRB(24, 40, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _SectionLabel('HOW THE CARDS WORK'),
          SizedBox(height: 20),
          _FeatureCard(
            icon: Icons.military_tech_outlined,
            color: AppTheme.primary,
            title: 'Tiers F through S',
            body: 'A card\'s tier comes from how viral the moment was at '
                'minting. Higher tiers hit harder but cost more Aura to play '
                '— stronger is never simply better, it\'s a real trade-off.',
          ),
          SizedBox(height: 12),
          _FeatureCard(
            icon: Icons.category_outlined,
            color: AppTheme.secondary,
            title: 'Families & effects',
            body: 'Each moment is classified into a family — athlete, '
                'musician, artist, scientist, comedian, and more. The family '
                'decides the card\'s effect style in battle, so decks have '
                'personality.',
          ),
          SizedBox(height: 12),
          _FeatureCard(
            icon: Icons.movie_outlined,
            color: AppTheme.success,
            title: 'Cinematic summons',
            body: 'Minting generates a short stylized cutscene of your '
                'moment. When you summon the card, the arena camera cuts '
                'into that clip — your moment literally enters the fight.',
          ),
          SizedBox(height: 12),
          _FeatureCard(
            icon: Icons.trending_up,
            color: Color(0xFFFFD700),
            title: 'Ascension',
            body: 'If a moment keeps gaining engagement after minting, its '
                'card can ascend to a higher tier — all copies together, at '
                'most once a week, and only between matches. Cards never '
                'de-rank.',
          ),
          SizedBox(height: 12),
          _FeatureCard(
            icon: Icons.swap_horiz,
            color: AppTheme.danger,
            title: 'Wager matches',
            body: 'In the optional wager mode, both players stake a card and '
                'the winner takes the loser\'s card. The original minter\'s '
                'handle stays on the card wherever it travels. Standard '
                'matches never risk your collection.',
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

// ─── Consent, ownership & likeness ────────────────────────────────────────────

class _ConsentSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel('YOUR MOMENTS, YOUR CONSENT'),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                  color: AppTheme.secondary.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: AppTheme.secondary.withValues(alpha: 0.1),
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(Icons.verified_user_outlined,
                        color: AppTheme.secondary, size: 20),
                  ),
                  const SizedBox(width: 12),
                  const Expanded(
                    child: Text('How ownership and likeness work',
                        style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700)),
                  ),
                ]),
                const SizedBox(height: 16),
                ...[
                  (
                    'Only your own posts',
                    'Cards can only be minted from a post on a social account '
                        'you\'ve verified you own. There is no minting from '
                        'random URLs or uploads of other people\'s content.'
                  ),
                  (
                    'Consent is explicit and specific',
                    'When you mint, you consent to that one moment being used '
                        'as a card. Playing for fun never requires giving up '
                        'anything else. Becoming a Market Maker is a separate, '
                        'explicit opt-in that covers markets on your popularity.'
                  ),
                  (
                    'You stay credited',
                    'Every card permanently carries the original minter\'s '
                        'handle — even if the card later changes hands in a '
                        'wager match.'
                  ),
                  (
                    'Moderation is mandatory',
                    'Every moment is screened before generation and every '
                        'finished card animation is screened again after. '
                        'Safety checks cannot be bypassed by anyone.'
                  ),
                  (
                    'One active self-minted card',
                    'You have one active self-minted card at a time. Minting a '
                        'new one replaces the old card after a clear warning — '
                        'so your best moment is always the one in play.'
                  ),
                  (
                    'Celebrity & creator packs are licensed',
                    'Premium moments from public figures only enter the game '
                        'through the licensing marketplace, with a recorded, '
                        'verifiable license behind every card.'
                  ),
                ].map((item) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Padding(
                            padding: EdgeInsets.only(top: 5),
                            child: Icon(Icons.circle,
                                size: 5, color: AppTheme.secondary),
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
        ],
      ),
    );
  }
}

// ─── The two market loops ─────────────────────────────────────────────────────

class _MarketsExplainer extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel('TWO KINDS OF PREDICTION MARKETS'),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.cardBorder),
            ),
            child: const Column(children: [
              _MarketRow(
                icon: Icons.bar_chart_outlined,
                title: 'Creator markets — tokens',
                body: 'Bet platform tokens on a creator\'s Display Score '
                    'going up or down. Tokens are the in-app currency; '
                    'during beta they are simulated.',
                color: AppTheme.primary,
              ),
              Divider(color: AppTheme.cardBorder, height: 28),
              _MarketRow(
                icon: Icons.sports_esports_outlined,
                title: 'Battle markets — real money',
                body: 'Spectators can back a player in a card battle with '
                    'real money (USD) — but only in matches where both '
                    'players are identity-verified. A slice of each battle '
                    'market goes to the creators whose moments were actually '
                    'played: summon your friend, your friend earns.',
                color: AppTheme.success,
              ),
              Divider(color: AppTheme.cardBorder, height: 28),
              _MarketRow(
                icon: Icons.gavel_outlined,
                title: 'One role per match',
                body: 'For any battle with an open money market, a person is '
                    'either a player or a bettor — never both. This is '
                    'enforced at the database level and cannot be toggled '
                    'off.',
                color: AppTheme.danger,
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

class _MarketRow extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final Color color;

  const _MarketRow({
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

// ─── Status: what's live vs coming ────────────────────────────────────────────

class _StatusSection extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel('WHERE THINGS STAND TODAY'),
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
                const Row(children: [
                  Icon(Icons.science_outlined,
                      color: AppTheme.secondary, size: 22),
                  SizedBox(width: 10),
                  Text('Beta status',
                      style: TextStyle(
                          color: AppTheme.secondary,
                          fontSize: 16,
                          fontWeight: FontWeight.w800)),
                ]),
                const SizedBox(height: 14),
                const Text(
                  'You can explore the whole platform right now. Money flows '
                  'run in simulation until launch:',
                  style: TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 13,
                      height: 1.6),
                ),
                const SizedBox(height: 12),
                ...[
                  'Creator prediction markets are live with simulated tokens',
                  'Card battles run in the Arena with server-side rules',
                  'Minting your own moment cards opens with launch',
                  'Real-money battle markets switch on only after identity '
                      'verification goes live',
                  'The Emergency Fund and licensing marketplace are running '
                      'in simulation mode',
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
              ],
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Community systems teaser ─────────────────────────────────────────────────

class _CommunityTeaser extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const _SectionLabel('BEYOND THE GAME'),
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: AppTheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: AppTheme.cardBorder),
            ),
            child: Column(children: [
              _TeaserItem(
                icon: Icons.volunteer_activism,
                title: 'Emergency Fund',
                body: 'A community mutual-aid pool. Members contribute, '
                    'requests are reviewed privately, and a randomly chosen '
                    'panel of contributors votes on each one.',
                color: AppTheme.success,
                onTap: () => context.push('/emergency-fund'),
              ),
              const Divider(color: AppTheme.cardBorder, height: 28),
              _TeaserItem(
                icon: Icons.workspace_premium_outlined,
                title: 'Likeness Licensing',
                body: 'A public marketplace for Right of Publicity licensing '
                    'with a verifiable registry — the same rail that powers '
                    'premium creator card packs.',
                color: AppTheme.primary,
                onTap: () => context.push('/licenses'),
              ),
              const Divider(color: AppTheme.cardBorder, height: 28),
              _TeaserItem(
                icon: Icons.local_fire_department_outlined,
                title: 'Hot Topic',
                body: 'A celebrity buzz leaderboard scored twice a day from '
                    'real news — a quick pulse on who the world is talking '
                    'about.',
                color: AppTheme.danger,
                onTap: () => context.push('/hot-topic'),
              ),
            ]),
          ),
        ],
      ),
    );
  }
}

class _TeaserItem extends StatelessWidget {
  final IconData icon;
  final String title;
  final String body;
  final Color color;
  final VoidCallback onTap;

  const _TeaserItem({
    required this.icon,
    required this.title,
    required this.body,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(8),
        child: Row(
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
            const Icon(Icons.chevron_right,
                color: AppTheme.textSecondary, size: 18),
          ],
        ),
      );
}

// ─── Get started CTA ──────────────────────────────────────────────────────────

class _GetStartedCta extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 40, 24, 0),
      child: SizedBox(
        width: double.infinity,
        child: ElevatedButton(
          onPressed: () => context.go('/signup'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppTheme.primary,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(vertical: 16),
            shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12)),
          ),
          child: const Text('Create your account',
              style:
                  TextStyle(fontWeight: FontWeight.w700, fontSize: 14)),
        ),
      ),
    );
  }
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
