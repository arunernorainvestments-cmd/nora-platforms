import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/widgets/battlechit_cta.dart';

class FaqScreen extends StatefulWidget {
  const FaqScreen({super.key});

  @override
  State<FaqScreen> createState() => _FaqScreenState();
}

class _FaqScreenState extends State<FaqScreen> {
  String _activeCategory = 'General';

  static const _categories = [
    'General',
    'Account',
    'Tokens & Wallet',
    'Markets',
    'Arena',
    'Moments Cards',
  ];

  static const _faqs = {
    'General': [
      _FAQ(
        question: 'What is N.O.R.A. Platforms?',
        answer: 'N.O.R.A. Platforms is a prediction market and card-battle platform for creator economies. You can bet on creator metrics, mint collectible "moment" cards from viral posts you own, battle with them, and support community systems like the Emergency Fund — all under one wallet.',
      ),
      _FAQ(
        question: 'Is N.O.R.A. available in my country?',
        answer: 'N.O.R.A. is currently in beta. We are rolling out access region by region. If you\'re on the waitlist, you\'ll receive an invite when we expand to your area. Currently the platform uses simulated tokens and does not involve real money wagering.',
      ),
      _FAQ(
        question: 'What devices can I use?',
        answer: 'N.O.R.A. is a web app accessible from any modern browser — desktop or mobile. We recommend Chrome, Safari, or Edge for the best experience.',
      ),
      _FAQ(
        question: 'How do I report a bug?',
        answer: 'Use the Support page to submit a help ticket and select "Technical Issue" as the category. Include as much detail as possible, including any error messages and the steps you took before the issue occurred.',
      ),
    ],
    'Account': [
      _FAQ(
        question: 'How do I reset my password?',
        answer: 'On the login screen, tap "Forgot password?" and enter your email address. You\'ll receive a password reset link within a few minutes. Check your spam folder if you don\'t see it.',
      ),
      _FAQ(
        question: 'How do I change my display name or bio?',
        answer: 'Go to your Profile tab, scroll to the edit section, and update your display name and bio. Tap "Save Changes" when you\'re done.',
      ),
      _FAQ(
        question: 'Can I delete my account?',
        answer: 'Account deletion is available on request. Submit a support ticket with the subject "Account Deletion Request" and our team will process it within 7 business days. Note that pending token balances and active bets must be resolved before deletion.',
      ),
      _FAQ(
        question: 'Why is my account pending approval?',
        answer: 'N.O.R.A. is currently in a closed beta. After signing up, your account is reviewed before access is granted. Approval typically happens within 24–72 hours. You\'ll receive an email once you\'re approved.',
      ),
    ],
    'Tokens & Wallet': [
      _FAQ(
        question: 'What are NORA tokens?',
        answer: 'NORA tokens are the in-platform currency used for placing bets in Markets and backing creators in Arena. During beta, all tokens are simulated and have no real monetary value.',
      ),
      _FAQ(
        question: 'How do I earn tokens?',
        answer: 'You receive a token grant when your account is approved. You can also earn tokens by winning Markets bets, winning Arena matches as a backer, completing challenges, and other platform activities.',
      ),
      _FAQ(
        question: 'Why is my token balance not updating?',
        answer: 'Token balances refresh automatically, but there can be a short delay of up to 30 seconds after a transaction. Pull down to refresh on the Wallet screen. If the issue persists after a few minutes, submit a support ticket.',
      ),
      _FAQ(
        question: 'Can I transfer tokens to another user?',
        answer: 'Direct token transfers between users are not currently supported. Tokens move through platform activities like Markets and Arena.',
      ),
    ],
    'Markets': [
      _FAQ(
        question: 'How do Markets work?',
        answer: 'In Markets, you bet on whether a creator\'s Display Score will go UP or DOWN over a set period. At resolution, the pool is split: 90% to winning bettors (proportional to their stake), 5% to the platform, and 5% to the Market Maker.',
      ),
      _FAQ(
        question: 'What is the Market Maker?',
        answer: 'The Market Maker is the creator whose Display Score the market is based on. They receive 5% of the total pool at resolution as a reward for participating in the platform.',
      ),
      _FAQ(
        question: 'When do markets resolve?',
        answer: 'Each market has a defined resolution date shown on the market detail page. Resolution is automatic when the end time is reached and a score comparison is made.',
      ),
      _FAQ(
        question: 'Can I cancel a bet?',
        answer: 'Bets cannot be cancelled once placed. Please review your bet carefully before confirming. You can view all active bets on the My Bets screen.',
      ),
    ],
    'Arena': [
      _FAQ(
        question: 'What is Arena?',
        answer: 'Arena is a live 5-minute 1v1 battle where two creators compete in real time. Backers wager tokens on their chosen creator before the match. The winning creator\'s backers share 90% of the total pool.',
      ),
      _FAQ(
        question: 'How is the Arena winner determined?',
        answer: 'The winner is determined by their ArenaScore — a real-time calculation of BaseFlow + HeatInfluence + AbilityImpact minus Suppression. The creator with the higher score when the timer expires wins.',
      ),
      _FAQ(
        question: 'What happens if an Arena match is cancelled?',
        answer: 'If a match is cancelled before completion, all backer tokens are refunded in full. You\'ll see the refund in your wallet within a few minutes.',
      ),
    ],
    'Moments Cards': [
      _FAQ(
        question: 'What is a moment card?',
        answer: 'A moment card (a "moment chit") is a collectible playing card minted from a real viral moment — a social post you own. The card gets stylized art, a tier (F up to S) based on how viral the moment was, and battle stats derived from that tier. Cards are game collectibles, not financial products.',
      ),
      _FAQ(
        question: 'How do I mint a card?',
        answer: 'Tap "Create Your BattleChit" (on Home, your Profile, or below), link a social account you own (TikTok, Instagram, or YouTube), and paste a link to one of your posts. Because the platforms don\'t let us download your video, you\'ll upload the clip from your device and trim the exact 1–15 seconds that is the moment. Every mint goes through content moderation before and after generation.',
      ),
      _FAQ(
        question: 'Who owns a card and its likeness?',
        answer: 'You can only mint from posts you own, and you give explicit consent at minting. Your handle stays attached to the card as the original minter, even if it changes hands later in a wager match. You keep ownership of your underlying content — the card is a licensed, in-game representation of that one moment.',
      ),
      _FAQ(
        question: 'What is KYC and why is it required?',
        answer: 'KYC (Know Your Customer) is an identity verification step. It\'s required to become a Market Maker and for matches with real-money prediction markets. It keeps the platform compliant and prevents duplicate accounts.',
      ),
      _FAQ(
        question: 'What is a wager match?',
        answer: 'A wager match is an optional battle mode where each player stakes a card from their collection. The winner takes the loser\'s staked card. Regular matches never put your cards at risk.',
      ),
    ],
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () => context.canPop() ? context.pop() : context.go('/home'),
        ),
        title: const Text('FAQ'),
      ),
      body: Column(
        children: [
          // Category chips
          SizedBox(
            height: 56,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              itemCount: _categories.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, i) {
                final cat = _categories[i];
                final active = cat == _activeCategory;
                return GestureDetector(
                  onTap: () => setState(() => _activeCategory = cat),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
                    decoration: BoxDecoration(
                      color: active ? AppTheme.primary : AppTheme.surface,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: active ? AppTheme.primary : AppTheme.cardBorder,
                        width: 1,
                      ),
                    ),
                    child: Text(
                      cat,
                      style: TextStyle(
                        color: active ? Colors.white : AppTheme.textSecondary,
                        fontSize: 13,
                        fontWeight: active ? FontWeight.w600 : FontWeight.normal,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),

          // FAQ list
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 32),
              children: [
                if (_activeCategory == 'Moments Cards')
                  const Padding(
                    padding: EdgeInsets.only(bottom: 12),
                    child: BattleChitButton(),
                  ),
                ..._faqs[_activeCategory]!.map((f) => _FaqTile(faq: f)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _FAQ {
  final String question;
  final String answer;
  const _FAQ({required this.question, required this.answer});
}

class _FaqTile extends StatefulWidget {
  final _FAQ faq;
  const _FaqTile({required this.faq});

  @override
  State<_FaqTile> createState() => _FaqTileState();
}

class _FaqTileState extends State<_FaqTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: _expanded ? AppTheme.primary.withValues(alpha: 0.4) : AppTheme.cardBorder,
          width: 1,
        ),
      ),
      child: InkWell(
        onTap: () => setState(() => _expanded = !_expanded),
        borderRadius: BorderRadius.circular(14),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.faq.question,
                      style: const TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        height: 1.4,
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  AnimatedRotation(
                    turns: _expanded ? 0.5 : 0,
                    duration: const Duration(milliseconds: 200),
                    child: const Icon(Icons.keyboard_arrow_down, color: AppTheme.textSecondary, size: 20),
                  ),
                ],
              ),
              AnimatedCrossFade(
                firstChild: const SizedBox.shrink(),
                secondChild: Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(
                    widget.faq.answer,
                    style: const TextStyle(
                      color: AppTheme.textSecondary,
                      fontSize: 13,
                      height: 1.6,
                    ),
                  ),
                ),
                crossFadeState: _expanded ? CrossFadeState.showSecond : CrossFadeState.showFirst,
                duration: const Duration(milliseconds: 200),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
