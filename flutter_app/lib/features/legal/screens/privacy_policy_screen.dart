import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/open_url.dart';

class PrivacyPolicyScreen extends StatelessWidget {
  const PrivacyPolicyScreen({super.key});

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
        title: const Text('Privacy Policy'),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _Heading('Privacy Policy'),
            const _Meta('N.O.R.A. Platforms, Inc.'),
            const _Meta('Effective Date: April 15, 2026'),
            const _Meta('Last Updated: April 15, 2026'),
            const SizedBox(height: 24),

            const _Body(
              'N.O.R.A. Platforms, Inc. ("N.O.R.A.", "we", "our", or "us") operates the '
              'N.O.R.A. Platforms application and website (collectively, the "Service"). '
              'This Privacy Policy describes how we collect, use, disclose, and protect '
              'your information when you use our Service. By using the Service, you agree '
              'to the practices described in this policy.',
            ),
            const SizedBox(height: 24),

            // 1. Information We Collect
            const _SectionTitle('1. Information We Collect'),

            const _SubTitle('1.1 Account Information'),
            const _Body(
              'When you create an account, we collect your email address, '
              'username, and password (stored securely via Supabase Auth — '
              'we never store plaintext passwords). If you sign up through a '
              'referral link, we record the referring user\'s identifier.',
            ),

            const _SubTitle('1.2 Platform Connections'),
            const _Body(
              'If you choose to connect a third-party content platform '
              '(currently YouTube or Twitch), we collect and store OAuth access '
              'tokens, refresh tokens, your platform username, and publicly '
              'available metrics such as follower count, subscriber count, and '
              'live viewer count. This data is used solely to compute your '
              'Heat Score and power market resolution. You may disconnect any '
              'platform at any time from your profile settings, which '
              'permanently deletes the associated tokens and metrics.',
            ),

            const _SubTitle('1.3 Activity Data'),
            const _Body(
              'We collect records of actions you take within the Service, '
              'including bets placed, markets created, token transactions '
              '(purchases, rewards, promotions, referral bonuses), promotions '
              'applied, badges earned, challenge progress, and streaks. This '
              'data is essential to the operation of the platform.',
            ),

            const _SubTitle('1.4 Payment Information'),
            const _Body(
              'Token purchases are processed by Stripe, Inc. We do not '
              'collect or store your credit card number or full payment details. '
              'We receive from Stripe a session identifier and confirmation of '
              'payment completion, which we use to credit tokens to your account. '
              'Please review Stripe\'s Privacy Policy for details on how Stripe '
              'handles your payment data.',
            ),

            const _SubTitle('1.5 Usage and Technical Data'),
            const _Body(
              'We may collect technical information such as your browser type, '
              'device type, IP address, pages visited within the Service, and '
              'timestamps of activity. This information is used to maintain '
              'security, diagnose issues, and improve the Service.',
            ),

            const SizedBox(height: 8),

            // 2. How We Use Your Information
            const _SectionTitle('2. How We Use Your Information'),
            const _Body('We use the information we collect to:'),
            const _BulletList([
              'Provide, operate, and maintain the Service',
              'Compute creator Heat Scores and resolve prediction markets',
              'Process token purchases and distribute rewards',
              'Evaluate challenge and badge progress',
              'Send in-app notifications relevant to your account activity',
              'Detect and prevent fraud, abuse, or unauthorized access',
              'Respond to your support requests',
              'Improve and develop new features of the Service',
              'Comply with legal obligations',
            ]),
            const SizedBox(height: 8),

            // 3. How We Share Your Information
            const _SectionTitle('3. How We Share Your Information'),
            const _Body(
              'We do not sell your personal information. We may share your '
              'information in the following limited circumstances:',
            ),
            const _BulletList([
              'Service Providers: We share data with Supabase (database and auth), '
                  'Stripe (payment processing), and Vercel (hosting) as necessary to '
                  'operate the Service. These providers are contractually bound to '
                  'protect your data.',
              'Third-Party Platforms: When you connect YouTube or Twitch, limited '
                  'OAuth credentials are exchanged with those platforms under their '
                  'respective terms of service.',
              'Legal Requirements: We may disclose information if required by law, '
                  'court order, or to protect the rights and safety of N.O.R.A. '
                  'Platforms, our users, or the public.',
              'Business Transfers: If N.O.R.A. Platforms is involved in a merger, '
                  'acquisition, or asset sale, your information may be transferred '
                  'as part of that transaction.',
            ]),
            const SizedBox(height: 8),

            // 4. Public Information
            const _SectionTitle('4. Public Information'),
            const _Body(
              'Certain information is visible to other users or to the public by '
              'design. This includes your username, profile bio, creator category, '
              'Heat Score, connected platform names, badge collection, and market '
              'activity. Do not include sensitive personal information in fields '
              'that are publicly visible.',
            ),
            const SizedBox(height: 8),

            // 5. Data Retention
            const _SectionTitle('5. Data Retention'),
            const _Body(
              'We retain your account information and activity data for as long '
              'as your account is active or as needed to provide the Service. '
              'If you request deletion of your account, we will delete or '
              'anonymize your personal data within 30 days, except where we are '
              'required to retain it for legal, regulatory, or fraud-prevention '
              'purposes. Token transaction records may be retained in anonymized '
              'form for financial record-keeping.',
            ),
            const SizedBox(height: 8),

            // 6. Data Security
            const _SectionTitle('6. Data Security'),
            const _Body(
              'We implement industry-standard security measures including '
              'encrypted data transmission (TLS), row-level security policies '
              'on our database, and access controls that restrict which '
              'operations can be performed by authenticated users versus our '
              'internal service layer. No method of transmission over the '
              'internet is 100% secure, and we cannot guarantee absolute security.',
            ),
            const SizedBox(height: 8),

            // 7. Children's Privacy
            const _SectionTitle('7. Children\'s Privacy'),
            const _Body(
              'The Service is not directed to individuals under the age of 13. '
              'We do not knowingly collect personal information from children '
              'under 13. If you believe we have inadvertently collected such '
              'information, please contact us immediately and we will take '
              'steps to delete it.',
            ),
            const SizedBox(height: 8),

            // 8. Your Rights and Choices
            const _SectionTitle('8. Your Rights and Choices'),
            const _Body(
              'Depending on your location, you may have certain rights regarding '
              'your personal data, including:',
            ),
            const _BulletList([
              'Access: Request a copy of the personal data we hold about you',
              'Correction: Request correction of inaccurate or incomplete data',
              'Deletion: Request deletion of your personal data',
              'Portability: Request your data in a portable format',
              'Opt-out: Disconnect platform integrations at any time from your '
                  'profile settings',
            ]),
            const _Body(
              'To exercise any of these rights, contact us at the email address '
              'below. We will respond within 30 days.',
            ),
            const SizedBox(height: 8),

            // 9. Third-Party Links
            const _SectionTitle('9. Third-Party Links and Services'),
            const _Body(
              'The Service may contain links to third-party websites or services '
              '(such as YouTube, Twitch, or Stripe). We are not responsible for '
              'the privacy practices of those third parties. We encourage you to '
              'review their privacy policies before providing any information.',
            ),
            const SizedBox(height: 8),

            // 10. Governing Law
            const _SectionTitle('10. Governing Law'),
            const _Body(
              'This Privacy Policy is governed by and construed in accordance '
              'with the laws of the State of Florida, United States, without '
              'regard to its conflict of law provisions.',
            ),
            const SizedBox(height: 8),

            // 11. Changes
            const _SectionTitle('11. Changes to This Policy'),
            const _Body(
              'We may update this Privacy Policy from time to time. When we do, '
              'we will update the "Last Updated" date at the top of this page. '
              'Continued use of the Service after changes are posted constitutes '
              'your acceptance of the revised policy. For material changes, we '
              'will make reasonable efforts to notify you in-app.',
            ),
            const SizedBox(height: 8),

            // 12. Contact
            const _SectionTitle('12. Contact Us'),
            const _Body(
              'If you have questions, concerns, or requests regarding this '
              'Privacy Policy or our data practices, please contact us at:',
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
      onTap: () => openUrlInBrowser(
          'mailto:privacy@noraplatforms.com'),
      child: const Text(
        'privacy@noraplatforms.com',
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
