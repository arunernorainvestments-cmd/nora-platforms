import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/theme/app_theme.dart';
import '../../../core/utils/open_url.dart';
import '../providers/kyc_providers.dart';

/// /verify-identity — identity verification status + start CTA.
/// Used to satisfy the staking KYC gate (one verified human → one staking account).
class KycScreen extends ConsumerStatefulWidget {
  const KycScreen({super.key});

  @override
  ConsumerState<KycScreen> createState() => _KycScreenState();
}

class _KycScreenState extends ConsumerState<KycScreen> {
  bool _busy = false;
  String? _error;

  Future<void> _verify() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final messenger = ScaffoldMessenger.of(context);
    try {
      final url = await ref.read(kycServiceProvider).startVerification();
      if (url != null) {
        // Live mode — redirect to the Stripe-hosted verification flow.
        await openUrlInBrowser(url);
      } else if (mounted) {
        // Sim mode — approved in place.
        messenger.showSnackBar(const SnackBar(content: Text('Identity verified')));
      }
    } catch (_) {
      if (mounted) setState(() => _error = 'Could not start verification. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final kyc = ref.watch(myKycProvider);
    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        title: const Text('Identity Verification',
            style: TextStyle(
                color: AppTheme.textPrimary, fontWeight: FontWeight.bold, fontSize: 18)),
        backgroundColor: AppTheme.surface,
        surfaceTintColor: Colors.transparent,
        elevation: 0,
      ),
      body: SafeArea(
        child: RefreshIndicator(
          onRefresh: () async => ref.invalidate(myKycProvider),
          child: ListView(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 24),
            children: [
              kyc.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(40),
                  child: Center(child: CircularProgressIndicator(color: AppTheme.primary)),
                ),
                error: (_, __) => const Text('Could not load status.',
                    style: TextStyle(color: AppTheme.textSecondary)),
                data: (info) => _content(info),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _content(KycInfo info) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _statusCard(info),
        const SizedBox(height: 20),
        const Text(
          'Why verify?',
          style: TextStyle(
              color: AppTheme.textPrimary, fontSize: 15, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 8),
        const Text(
          'Verification keeps prediction markets fair: one verified person gets one '
          'staking account, and players in a match can\'t also bet on it. Your documents '
          'are reviewed by our identity provider and are never shared.',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 13, height: 1.5),
        ),
        const SizedBox(height: 24),
        if (_error != null) ...[
          Text(_error!, style: const TextStyle(color: AppTheme.danger, fontSize: 13)),
          const SizedBox(height: 12),
        ],
        if (!info.isApproved)
          ElevatedButton(
            onPressed: _busy ? null : _verify,
            style: ElevatedButton.styleFrom(
              backgroundColor: AppTheme.primary,
              foregroundColor: Colors.white,
              minimumSize: const Size(double.infinity, 50),
            ),
            child: _busy
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : Text(info.isPending ? 'Continue verification' : 'Verify my identity'),
          ),
      ],
    );
  }

  Widget _statusCard(KycInfo info) {
    late final Color color;
    late final IconData icon;
    late final String title;
    late final String subtitle;

    if (info.isApproved) {
      color = AppTheme.success;
      icon = Icons.verified_user_rounded;
      title = 'Verified';
      subtitle = 'Your identity is verified. You can stake on markets.';
    } else if (info.isPending) {
      color = const Color(0xFFFFB300);
      icon = Icons.hourglass_top_rounded;
      title = 'In review';
      subtitle = 'We\'re reviewing your documents. This usually takes a few minutes.';
    } else if (info.isRejected) {
      color = AppTheme.danger;
      icon = Icons.gpp_bad_rounded;
      title = 'Not verified';
      subtitle = info.rejectedReason ?? 'Verification was not successful. Please try again.';
    } else {
      color = AppTheme.primary;
      icon = Icons.badge_outlined;
      title = 'Not verified yet';
      subtitle = 'Verify your identity to place bets in prediction markets.';
    }

    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Row(
        children: [
          Icon(icon, color: color, size: 30),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: TextStyle(
                        color: color, fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 4),
                Text(subtitle,
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 13, height: 1.4)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
