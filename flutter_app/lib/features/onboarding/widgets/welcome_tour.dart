import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/local_flags.dart';

// First-login walkthrough. Shown once per user (localStorage flag keyed by
// user id) the first time they land on /home signed in; re-openable any time
// from the side drawer ("Take the tour").

String _tourFlagKey(String userId) => 'nora_welcome_tour_seen_$userId';

// Shows the tour if this user hasn't seen it yet.
void maybeShowWelcomeTour(BuildContext context, String userId) {
  if (LocalFlags.get(_tourFlagKey(userId))) return;
  LocalFlags.set(_tourFlagKey(userId), true);
  showWelcomeTour(context);
}

void showWelcomeTour(BuildContext context) {
  showDialog(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.black.withValues(alpha: 0.7),
    builder: (_) => const _WelcomeTourDialog(),
  );
}

class _TourPage {
  final IconData icon;
  final Color color;
  final String title;
  final String body;
  final String? hint; // "where to find it"
  const _TourPage({
    required this.icon,
    required this.color,
    required this.title,
    required this.body,
    this.hint,
  });
}

const _pages = [
  _TourPage(
    icon: Icons.rocket_launch_outlined,
    color: AppTheme.primary,
    title: 'Welcome to N.O.R.A.',
    body: 'One platform, two loops: predict the rise of creators in the '
        'markets, and battle with collectible cards minted from real viral '
        'moments. Home is your feed — champions, top movers, news, and '
        'community.',
    hint: 'You are here: the Home tab.',
  ),
  _TourPage(
    icon: Icons.person_outline,
    color: AppTheme.secondary,
    title: 'Set up your profile',
    body: 'Add your display name and, if you like, link the social accounts '
        'you own. Linking is optional — it unlocks minting your own cards. '
        'Creators can also opt in as a Market Maker (identity verification '
        'required) to let fans back them in the markets.',
    hint: 'Profile tab → Connections.',
  ),
  _TourPage(
    icon: Icons.style_outlined,
    color: AppTheme.secondary,
    title: 'Your starter deck is already yours',
    body: 'Every account opens with the Standard Playset: 30 NORA-original '
        'cards, 2 copies of each. That is a real deck on day one — enough to '
        'build thousands of legal 20-card decks and discover fusions. Starters '
        'are free forever and never bought, sold, or traded.',
    hint: 'Collection tab → Build a deck.',
  ),
  _TourPage(
    icon: Icons.auto_awesome_outlined,
    color: Color(0xFFFFD700),
    title: 'Now mint YOUR moment',
    body: 'The starters are the floor. The point is the card only you can '
        'make: pick a viral post you own and mint it into a playable card. Its '
        'tier (F up to S) comes from how viral the moment was — stats are '
        'derived, never bought. You preview every card in a practice battle '
        'before it\'s final.',
    hint: 'Collection tab → Mint your moment.',
  ),
  _TourPage(
    icon: Icons.style_outlined,
    color: AppTheme.danger,
    title: 'Battle',
    body: 'Build a 20-card deck and fight: summon creatures and cast '
        'spell-moments with Aura that grows every turn, and bring your '
        'opponent\'s Life to zero. Feeling bold? Wager matches let the '
        'winner take one of the loser\'s cards.',
    hint: 'Battle tab in the bottom bar.',
  ),
  _TourPage(
    icon: Icons.bar_chart_outlined,
    color: AppTheme.success,
    title: 'Predict the markets',
    body: 'Bet tokens on whether a creator\'s score goes up or down — '
        'winners share 90% of the pool. Card battles between verified '
        'players get their own spectator markets. You\'re always either a '
        'player or a bettor in a match, never both.',
    hint: 'Markets tab · My Bets in the menu.',
  ),
  _TourPage(
    icon: Icons.account_balance_wallet_outlined,
    color: AppTheme.primary,
    title: 'Your wallet',
    body: 'Tokens power your bets and boosts. Earn them through challenges, '
        'invites, and wins — or grab a package. During beta all tokens are '
        'simulated, so explore freely. That\'s the tour — have fun!',
    hint: 'Wallet tab · "Get Tokens" up top.',
  ),
];

class _WelcomeTourDialog extends StatefulWidget {
  const _WelcomeTourDialog();

  @override
  State<_WelcomeTourDialog> createState() => _WelcomeTourDialogState();
}

class _WelcomeTourDialogState extends State<_WelcomeTourDialog> {
  final _controller = PageController();
  int _page = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _next() {
    if (_page == _pages.length - 1) {
      Navigator.of(context).pop();
      return;
    }
    _controller.nextPage(
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    final isLast = _page == _pages.length - 1;

    return Dialog(
      backgroundColor: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
        side: const BorderSide(color: AppTheme.cardBorder),
      ),
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Skip row
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    'QUICK TOUR · ${_page + 1}/${_pages.length}',
                    style: TextStyle(
                      color: AppTheme.textSecondary.withValues(alpha: 0.7),
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.2,
                    ),
                  ),
                  GestureDetector(
                    onTap: () => Navigator.of(context).pop(),
                    child: const Text('Skip',
                        style: TextStyle(
                            color: AppTheme.textSecondary, fontSize: 13)),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              SizedBox(
                height: 320,
                child: PageView.builder(
                  controller: _controller,
                  itemCount: _pages.length,
                  onPageChanged: (i) => setState(() => _page = i),
                  itemBuilder: (context, i) {
                    final p = _pages[i];
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 72,
                          height: 72,
                          decoration: BoxDecoration(
                            color: p.color.withValues(alpha: 0.12),
                            shape: BoxShape.circle,
                            border: Border.all(
                                color: p.color.withValues(alpha: 0.4)),
                          ),
                          child: Icon(p.icon, color: p.color, size: 32),
                        ),
                        const SizedBox(height: 20),
                        Text(p.title,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 19,
                                fontWeight: FontWeight.w800)),
                        const SizedBox(height: 12),
                        Text(p.body,
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                                color: AppTheme.textSecondary,
                                fontSize: 13.5,
                                height: 1.6)),
                        if (p.hint != null) ...[
                          const SizedBox(height: 14),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 6),
                            decoration: BoxDecoration(
                              color: p.color.withValues(alpha: 0.08),
                              borderRadius: BorderRadius.circular(20),
                              border: Border.all(
                                  color: p.color.withValues(alpha: 0.25)),
                            ),
                            child: Text(p.hint!,
                                style: TextStyle(
                                    color: p.color,
                                    fontSize: 11.5,
                                    fontWeight: FontWeight.w600)),
                          ),
                        ],
                      ],
                    );
                  },
                ),
              ),
              const SizedBox(height: 12),
              // Dots
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: List.generate(_pages.length, (i) {
                  final active = i == _page;
                  return AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: active ? 18 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: active
                          ? AppTheme.primary
                          : AppTheme.cardBorder,
                      borderRadius: BorderRadius.circular(3),
                    ),
                  );
                }),
              ),
              const SizedBox(height: 16),
              Row(
                children: [
                  if (_page > 0)
                    TextButton(
                      onPressed: () => _controller.previousPage(
                        duration: const Duration(milliseconds: 250),
                        curve: Curves.easeOut,
                      ),
                      child: const Text('Back',
                          style: TextStyle(
                              color: AppTheme.textSecondary, fontSize: 13)),
                    ),
                  const Spacer(),
                  ElevatedButton(
                    onPressed: _next,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: AppTheme.primary,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 28, vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10)),
                    ),
                    child: Text(isLast ? "Let's go" : 'Next',
                        style: const TextStyle(
                            fontWeight: FontWeight.w700, fontSize: 13)),
                  ),
                ],
              ),
              if (isLast) ...[
                const SizedBox(height: 8),
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                    context.push('/plan');
                  },
                  child: const Text('Read the full "How it works" page →',
                      style: TextStyle(
                          color: AppTheme.secondary, fontSize: 12)),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
