import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../models/ubi_models.dart';
import '../providers/ubi_providers.dart';

class EmergencyFundScreen extends ConsumerWidget {
  const EmergencyFundScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final balanceAsync = ref.watch(ubiPoolBalanceProvider);
    final configAsync = ref.watch(ubiPoolConfigProvider);
    final disbursementsAsync = ref.watch(ubiPublicDisbursementsProvider);
    final isLoggedIn = Supabase.instance.client.auth.currentUser != null;

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: const Text('N.O.R.A. Emergency Fund',
            style: TextStyle(color: AppTheme.textPrimary)),
        iconTheme: const IconThemeData(color: AppTheme.textPrimary),
        actions: [
          if (isLoggedIn)
            TextButton(
              onPressed: () => context.push('/emergency-fund/my-requests'),
              child: const Text('My Requests',
                  style: TextStyle(color: AppTheme.primary)),
            ),
        ],
      ),
      body: RefreshIndicator(
        color: AppTheme.primary,
        backgroundColor: AppTheme.surface,
        onRefresh: () async {
          ref.invalidate(ubiPoolBalanceProvider);
          ref.invalidate(ubiPublicDisbursementsProvider);
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            // ── Hero ─────────────────────────────────────────────────────────
            _HeroBanner(),

            const SizedBox(height: 20),

            // ── Pool balance card ─────────────────────────────────────────────
            balanceAsync.when(
              data: (balance) => configAsync.when(
                data: (config) => _PoolBalanceCard(
                  balance: balance,
                  config: config,
                  isLoggedIn: isLoggedIn,
                ),
                loading: () => const _LoadingCard(),
                error: (e, _) => const SizedBox.shrink(),
              ),
              loading: () => const _LoadingCard(),
              error: (e, _) => const SizedBox.shrink(),
            ),

            const SizedBox(height: 24),

            // ── How it works ──────────────────────────────────────────────────
            const _HowItWorksSection(),

            const SizedBox(height: 24),

            // ── Recent impact strip ───────────────────────────────────────────
            disbursementsAsync.when(
              data: (items) => items.isEmpty
                  ? const SizedBox.shrink()
                  : _RecentImpactSection(items: items),
              loading: () => const SizedBox.shrink(),
              error: (_, __) => const SizedBox.shrink(),
            ),

            const SizedBox(height: 24),

            // ── FAQ ───────────────────────────────────────────────────────────
            const _FaqSection(),

            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }
}

// ─── Hero banner ─────────────────────────────────────────────────────────────

class _HeroBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            AppTheme.primary.withValues(alpha: 0.15),
            AppTheme.secondary.withValues(alpha: 0.08),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.primary.withValues(alpha: 0.3)),
      ),
      child: const Column(
        children: [
          Icon(Icons.volunteer_activism, color: AppTheme.primary, size: 40),
          SizedBox(height: 12),
          Text(
            'N.O.R.A. Emergency Fund',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.bold),
            textAlign: TextAlign.center,
          ),
          SizedBox(height: 8),
          Text(
            'A community-powered emergency fund.\nAnyone can give. Anyone can ask.',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 14),
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}

// ─── Pool balance card ────────────────────────────────────────────────────────

class _PoolBalanceCard extends StatelessWidget {
  final UbiPoolBalance balance;
  final UbiPoolConfig config;
  final bool isLoggedIn;

  const _PoolBalanceCard({
    required this.balance,
    required this.config,
    required this.isLoggedIn,
  });

  @override
  Widget build(BuildContext context) {
    final displayBalance = config.isSimulated
        ? balance.simBalanceCents
        : balance.liveBalanceCents;
    final dollars = (displayBalance / 100).toStringAsFixed(0);

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        children: [
          const Text('Community Pool',
              style: TextStyle(color: AppTheme.textSecondary, fontSize: 13)),
          const SizedBox(height: 4),
          Text(
            '\$$dollars',
            style: const TextStyle(
                color: AppTheme.success,
                fontSize: 40,
                fontWeight: FontWeight.bold),
          ),
          const Text(
            'held securely by Stripe',
            style: TextStyle(color: AppTheme.textSecondary, fontSize: 12),
          ),
          if (config.isSimulated)
            Container(
              margin: const EdgeInsets.only(top: 6),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.1),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text('Simulated funds — pre-launch testing mode',
                  style: TextStyle(color: AppTheme.primary, fontSize: 11)),
            ),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: FilledButton(
                  onPressed: config.isOpenForContributions
                      ? () => context.push('/emergency-fund/contribute')
                      : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: AppTheme.secondary,
                    foregroundColor: Colors.black,
                  ),
                  child: const Text('Contribute'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton(
                  onPressed: config.isOpenForRequests
                      ? () {
                          if (isLoggedIn) {
                            context.push('/emergency-fund/request');
                          } else {
                            context.push('/login?next=/emergency-fund/request');
                          }
                        }
                      : null,
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.primary,
                    side: const BorderSide(color: AppTheme.primary),
                  ),
                  child: const Text('Request Funds'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── How it works ─────────────────────────────────────────────────────────────

class _HowItWorksSection extends StatelessWidget {
  const _HowItWorksSection();

  @override
  Widget build(BuildContext context) {
    return const Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('How it works',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold)),
        SizedBox(height: 12),
        _StepTile(
          step: '1',
          icon: Icons.edit_note,
          text: 'Tell us your need. Our AI reviews your request privately.',
        ),
        _StepTile(
          step: '2',
          icon: Icons.how_to_vote,
          text: 'A random panel of fund contributors votes anonymously.',
        ),
        _StepTile(
          step: '3',
          icon: Icons.attach_money,
          text: 'If approved, funds are sent directly to you via Stripe.',
        ),
      ],
    );
  }
}

class _StepTile extends StatelessWidget {
  final String step;
  final IconData icon;
  final String text;

  const _StepTile({required this.step, required this.icon, required this.text});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              color: AppTheme.primary.withValues(alpha: 0.15),
            ),
            child: Center(
              child: Text(step,
                  style: const TextStyle(
                      color: AppTheme.primary, fontWeight: FontWeight.bold)),
            ),
          ),
          const SizedBox(width: 12),
          Icon(icon, color: AppTheme.primary, size: 20),
          const SizedBox(width: 10),
          Expanded(
            child: Text(text,
                style: const TextStyle(
                    color: AppTheme.textPrimary, fontSize: 14)),
          ),
        ],
      ),
    );
  }
}

// ─── Recent impact strip ──────────────────────────────────────────────────────

class _RecentImpactSection extends StatelessWidget {
  final List<UbiPublicDisbursement> items;

  const _RecentImpactSection({required this.items});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Recent Impact',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 12),
        ...items.map((item) => _ImpactTile(item: item)),
      ],
    );
  }
}

class _ImpactTile extends StatelessWidget {
  final UbiPublicDisbursement item;

  const _ImpactTile({required this.item});

  @override
  Widget build(BuildContext context) {
    final dollars = (item.amountCents / 100).toStringAsFixed(0);
    final category = item.emergencyCategory[0].toUpperCase() +
        item.emergencyCategory.substring(1);

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Row(
        children: [
          const Icon(Icons.check_circle, color: AppTheme.success, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '$category · ${item.monthYear}',
              style: const TextStyle(
                  color: AppTheme.textPrimary, fontWeight: FontWeight.w600),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('\$$dollars',
                  style: const TextStyle(
                      color: AppTheme.success,
                      fontWeight: FontWeight.bold,
                      fontSize: 15)),
              Text('${item.votesYes} of ${item.votesTotal} voted yes',
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 11)),
            ],
          ),
        ],
      ),
    );
  }
}

// ─── FAQ accordion ────────────────────────────────────────────────────────────

class _FaqSection extends StatelessWidget {
  const _FaqSection();

  @override
  Widget build(BuildContext context) {
    const faqs = [
      ('Who can contribute?',
       'Anyone. No account required. Contributions can be anonymous.'),
      ('Who can request funds?',
       'Anyone with a NORA account who is facing a genuine emergency.'),
      ('Who decides if I get funds?',
       'A randomly selected group of contributors votes. The community decides — not the platform.'),
      ('Does the platform keep any of the money?',
       'No. Stripe holds the pool. NORA facilitates the process only.'),
      ('Are my documents private?',
       'Yes. Only the AI reads them to understand your situation. Voters never see your documents.'),
      ('What counts as an emergency?',
       'Medical bills, rent/eviction, utility shutoffs, food insecurity, transportation for work, funeral costs, and disaster recovery.'),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Questions',
            style: TextStyle(
                color: AppTheme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.bold)),
        const SizedBox(height: 8),
        ...faqs.map((faq) => _FaqTile(question: faq.$1, answer: faq.$2)),
      ],
    );
  }
}

class _FaqTile extends StatefulWidget {
  final String question;
  final String answer;

  const _FaqTile({required this.question, required this.answer});

  @override
  State<_FaqTile> createState() => _FaqTileState();
}

class _FaqTileState extends State<_FaqTile> {
  bool _expanded = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: () => setState(() => _expanded = !_expanded),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(widget.question,
                        style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 14)),
                  ),
                  Icon(
                    _expanded ? Icons.expand_less : Icons.expand_more,
                    color: AppTheme.textSecondary,
                    size: 20,
                  ),
                ],
              ),
              if (_expanded) ...[
                const SizedBox(height: 8),
                Text(widget.answer,
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 13)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Shared helpers ───────────────────────────────────────────────────────────

class _LoadingCard extends StatelessWidget {
  const _LoadingCard();

  @override
  Widget build(BuildContext context) => Container(
        height: 80,
        decoration: BoxDecoration(
          color: AppTheme.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppTheme.cardBorder),
        ),
        child: const Center(
          child: CircularProgressIndicator(color: AppTheme.primary),
        ),
      );
}
