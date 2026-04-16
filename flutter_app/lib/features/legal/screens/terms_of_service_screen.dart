import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/open_url.dart';

class TermsOfServiceScreen extends StatelessWidget {
  const TermsOfServiceScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          onPressed: () {
            if (context.canPop()) {
              context.pop();
            } else {
              context.go('/home');
            }
          },
        ),
        title: const Text('Terms of Service'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Heading('Terms of Service'),
            const _Meta('N.O.R.A. Platforms, Inc.'),
            const _Meta('Effective Date: April 15, 2026'),
            const _Meta('Last Updated: April 15, 2026'),
            const SizedBox(height: 24),

            const _Body(
              'Please read these Terms of Service ("Terms") carefully before using '
              'the N.O.R.A. Platforms application and website (collectively, the "Service") '
              'operated by N.O.R.A. Platforms, Inc. ("N.O.R.A.", "we", "our", or "us"). '
              'By accessing or using the Service, you agree to be bound by these Terms. '
              'If you do not agree to these Terms, do not use the Service.',
            ),
            const SizedBox(height: 24),

            // 1. Eligibility
            const _SectionTitle('1. Eligibility'),
            const _Body(
              'You must be at least 13 years of age to use the Service. By using the '
              'Service, you represent and warrant that you meet this age requirement and '
              'that you have the legal capacity to enter into these Terms. If you are '
              'between 13 and 18 years of age, you represent that a parent or legal '
              'guardian has reviewed and agreed to these Terms on your behalf.',
            ),
            const SizedBox(height: 8),

            // 2. Accounts
            const _SectionTitle('2. Accounts'),
            const _SubTitle('2.1 Registration'),
            const _Body(
              'You must create an account to access most features of the Service. '
              'You agree to provide accurate, current, and complete information during '
              'registration and to keep your account information up to date. You are '
              'responsible for maintaining the confidentiality of your login credentials '
              'and for all activity that occurs under your account.',
            ),

            const _SubTitle('2.2 One Account Per User'),
            const _Body(
              'You may only maintain one account. Creating multiple accounts to '
              'circumvent bans, earn duplicate referral bonuses, or gain any unfair '
              'advantage is prohibited and may result in permanent suspension of all '
              'associated accounts.',
            ),

            const _SubTitle('2.3 Account Termination'),
            const _Body(
              'We reserve the right to suspend or terminate your account at any time, '
              'with or without notice, for violation of these Terms or for any other '
              'reason at our sole discretion. You may request deletion of your account '
              'by contacting us at the address below.',
            ),
            const SizedBox(height: 8),

            // 3. Platform Tokens
            const _SectionTitle('3. Platform Tokens'),
            const _SubTitle('3.1 Nature of Tokens'),
            const _Body(
              'N.O.R.A. Platform Tokens ("Tokens") are a virtual in-app currency with '
              'no real-world monetary value. Tokens are not redeemable for cash, '
              'transferable to other users, or exchangeable for any real-world goods '
              'or services. Tokens are solely used to participate in platform features '
              'such as prediction markets, promotions, and power-ups.',
            ),

            const _SubTitle('3.2 Token Purchases'),
            const _Body(
              'You may purchase Tokens using real currency through our third-party '
              'payment processor, Stripe. All Token purchases are final and '
              'non-refundable, except as required by applicable law. Token prices are '
              'subject to change at any time.',
            ),

            const _SubTitle('3.3 Token Forfeiture'),
            const _Body(
              'Tokens are non-transferable and will be forfeited upon account '
              'termination. We reserve the right to adjust, remove, or reset Token '
              'balances if we determine they were obtained through fraudulent activity, '
              'exploitation of bugs, or violation of these Terms.',
            ),
            const SizedBox(height: 8),

            // 4. Prediction Markets
            const _SectionTitle('4. Prediction Markets'),
            const _SubTitle('4.1 Entertainment Purpose Only'),
            const _Body(
              'All prediction market activity on the Service is conducted using '
              'Tokens only and is intended solely for entertainment purposes. '
              'No real money is wagered or won. The Service does not constitute '
              'gambling as defined under applicable law.',
            ),

            const _SubTitle('4.2 Market Resolution'),
            const _Body(
              'Markets are resolved based on objective platform metrics (follower '
              'counts and subscriber counts) fetched from connected third-party APIs '
              'at the time of market close. We make no guarantee that third-party '
              'API data will be available or accurate at resolution time. In cases '
              'where resolution data is unavailable or inconclusive, we reserve the '
              'right to void a market and refund all stakes.',
            ),

            const _SubTitle('4.3 Market Maker Role'),
            const _Body(
              'Users who opt into the Market Maker role may earn a 5% fee from '
              'resolved markets on their creator profile. Market Maker status may '
              'be revoked at any time for violations of these Terms.',
            ),
            const SizedBox(height: 8),

            // 5. Prohibited Conduct
            const _SectionTitle('5. Prohibited Conduct'),
            const _Body('You agree not to:'),
            const _BulletList([
              'Use the Service for any unlawful purpose or in violation of these Terms',
              'Create multiple accounts or use bots, scripts, or automation to '
                  'manipulate scores, markets, or token balances',
              'Exploit bugs or vulnerabilities — report them responsibly to us instead',
              'Harass, threaten, or harm other users',
              'Impersonate any person or entity',
              'Attempt to gain unauthorized access to any part of the Service or '
                  'its infrastructure',
              'Reverse engineer, decompile, or disassemble any part of the Service',
              'Manipulate Heat Scores, prediction markets, or leaderboards through '
                  'coordinated or artificial means',
              'Use the Service to transmit spam, malware, or any harmful content',
            ]),
            const SizedBox(height: 8),

            // 6. Third-Party Platforms
            const _SectionTitle('6. Third-Party Platform Connections'),
            const _Body(
              'The Service allows you to connect third-party accounts (currently '
              'YouTube and Twitch) via OAuth. By connecting a platform, you authorize '
              'us to access specified public data from that platform on your behalf. '
              'Your use of those platforms remains subject to their respective terms '
              'of service. We are not responsible for any changes to third-party APIs '
              'that affect Service functionality.',
            ),
            const SizedBox(height: 8),

            // 7. Intellectual Property
            const _SectionTitle('7. Intellectual Property'),
            const _Body(
              'All content, features, and functionality of the Service — including '
              'but not limited to text, graphics, logos, and software — are owned by '
              'N.O.R.A. Platforms, Inc. or its licensors and are protected by applicable '
              'intellectual property laws. You are granted a limited, non-exclusive, '
              'non-transferable license to use the Service for personal, non-commercial '
              'purposes. You may not copy, modify, distribute, sell, or lease any part '
              'of the Service without our prior written consent.',
            ),
            const SizedBox(height: 8),

            // 8. User Content
            const _SectionTitle('8. User Content'),
            const _Body(
              'By submitting any content to the Service (including your username, '
              'bio, or other profile information), you grant N.O.R.A. Platforms, Inc. '
              'a worldwide, royalty-free, perpetual license to use, display, and '
              'distribute that content in connection with operating and promoting the '
              'Service. You represent that you have all necessary rights to grant '
              'this license.',
            ),
            const SizedBox(height: 8),

            // 9. Disclaimers
            const _SectionTitle('9. Disclaimers'),
            const _Body(
              'THE SERVICE IS PROVIDED "AS IS" AND "AS AVAILABLE" WITHOUT WARRANTIES '
              'OF ANY KIND, EXPRESS OR IMPLIED. TO THE FULLEST EXTENT PERMITTED BY '
              'APPLICABLE LAW, N.O.R.A. PLATFORMS, INC. DISCLAIMS ALL WARRANTIES, '
              'INCLUDING IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A '
              'PARTICULAR PURPOSE, AND NON-INFRINGEMENT. WE DO NOT WARRANT THAT THE '
              'SERVICE WILL BE UNINTERRUPTED, ERROR-FREE, OR FREE OF HARMFUL COMPONENTS.',
            ),
            const SizedBox(height: 8),

            // 10. Limitation of Liability
            const _SectionTitle('10. Limitation of Liability'),
            const _Body(
              'TO THE MAXIMUM EXTENT PERMITTED BY APPLICABLE LAW, N.O.R.A. PLATFORMS, '
              'INC. AND ITS OFFICERS, DIRECTORS, EMPLOYEES, AND AGENTS SHALL NOT BE '
              'LIABLE FOR ANY INDIRECT, INCIDENTAL, SPECIAL, CONSEQUENTIAL, OR PUNITIVE '
              'DAMAGES ARISING FROM YOUR USE OF OR INABILITY TO USE THE SERVICE, EVEN '
              'IF WE HAVE BEEN ADVISED OF THE POSSIBILITY OF SUCH DAMAGES. OUR TOTAL '
              'LIABILITY TO YOU FOR ANY CLAIM ARISING FROM THESE TERMS OR THE SERVICE '
              'SHALL NOT EXCEED THE GREATER OF (A) THE AMOUNT YOU PAID US IN THE '
              'TWELVE MONTHS PRECEDING THE CLAIM OR (B) ONE HUNDRED U.S. DOLLARS.',
            ),
            const SizedBox(height: 8),

            // 11. Indemnification
            const _SectionTitle('11. Indemnification'),
            const _Body(
              'You agree to indemnify, defend, and hold harmless N.O.R.A. Platforms, '
              'Inc. and its officers, directors, employees, and agents from and against '
              'any claims, liabilities, damages, losses, and expenses (including '
              'reasonable legal fees) arising from your use of the Service, your '
              'violation of these Terms, or your violation of any rights of another person.',
            ),
            const SizedBox(height: 8),

            // 12. Governing Law & Disputes
            const _SectionTitle('12. Governing Law and Dispute Resolution'),
            const _Body(
              'These Terms are governed by and construed in accordance with the laws '
              'of the State of Florida, United States, without regard to its conflict '
              'of law provisions. Any dispute arising from or relating to these Terms '
              'or the Service shall be resolved exclusively in the state or federal '
              'courts located in Florida, and you consent to personal jurisdiction '
              'in those courts.',
            ),
            const SizedBox(height: 8),

            // 13. Changes
            const _SectionTitle('13. Changes to These Terms'),
            const _Body(
              'We may update these Terms from time to time. When we do, we will '
              'update the "Last Updated" date at the top of this page. Continued '
              'use of the Service after changes are posted constitutes your '
              'acceptance of the revised Terms. For material changes, we will make '
              'reasonable efforts to notify you in-app.',
            ),
            const SizedBox(height: 8),

            // 14. Contact
            const _SectionTitle('14. Contact Us'),
            const _Body(
              'If you have questions or concerns about these Terms, please contact us at:',
            ),
            const SizedBox(height: 8),
            const _Body('N.O.R.A. Platforms, Inc.'),
            _ContactEmail(),
            const SizedBox(height: 48),
          ],
        ),
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Private widgets
// ─────────────────────────────────────────────────────────────────────────────

class _Heading extends StatelessWidget {
  final String text;
  const _Heading(this.text);

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: const TextStyle(
        color: AppTheme.textPrimary,
        fontSize: 26,
        fontWeight: FontWeight.bold,
      ),
    );
  }
}

class _Meta extends StatelessWidget {
  final String text;
  const _Meta(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Text(
        text,
        style: const TextStyle(color: AppTheme.textSecondary, fontSize: 13),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String text;
  const _SectionTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          color: AppTheme.textPrimary,
          fontSize: 16,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _SubTitle extends StatelessWidget {
  final String text;
  const _SubTitle(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 12, bottom: 4),
      child: Text(
        text,
        style: const TextStyle(
          color: AppTheme.textPrimary,
          fontSize: 14,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class _Body extends StatelessWidget {
  final String text;
  const _Body(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        text,
        style: const TextStyle(
          color: AppTheme.textSecondary,
          fontSize: 14,
          height: 1.6,
        ),
      ),
    );
  }
}

class _BulletList extends StatelessWidget {
  final List<String> items;
  const _BulletList(this.items);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 8, bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: items
            .map(
              (item) => Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('• ',
                        style: TextStyle(
                            color: AppTheme.textSecondary, fontSize: 14)),
                    Expanded(
                      child: Text(
                        item,
                        style: const TextStyle(
                          color: AppTheme.textSecondary,
                          fontSize: 14,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _ContactEmail extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => openUrlInBrowser('mailto:aruner.norainvestments@gmail.com'),
      child: const Text(
        'aruner.norainvestments@gmail.com',
        style: TextStyle(
          color: AppTheme.primary,
          fontSize: 14,
          decoration: TextDecoration.underline,
          decorationColor: AppTheme.primary,
        ),
      ),
    );
  }
}
