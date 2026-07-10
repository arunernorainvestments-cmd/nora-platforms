import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../licensing_format.dart';
import '../providers/licensing_providers.dart';
import '../../../core/widgets/n_back_button.dart';

/// Licenses the current user holds. Each card links to the public record and
/// offers a "Sync to Arena App" deep link (doc6 integration).
class MyLicensesScreen extends ConsumerWidget {
  const MyLicensesScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final licensesAsync = ref.watch(myLicensesProvider);

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: const NBackButton(fallback: '/licenses'),
        backgroundColor: AppTheme.surface,
        title: const Text('My Licenses',
            style: TextStyle(color: AppTheme.textPrimary)),
        iconTheme: const IconThemeData(color: AppTheme.textPrimary),
      ),
      body: RefreshIndicator(
        color: AppTheme.primary,
        backgroundColor: AppTheme.surface,
        onRefresh: () async => ref.invalidate(myLicensesProvider),
        child: licensesAsync.when(
          loading: () => const Center(
              child: CircularProgressIndicator(color: AppTheme.primary)),
          error: (e, _) => ListView(children: [
            Padding(
              padding: const EdgeInsets.all(32),
              child: Text('Could not load your licenses.\n$e',
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: AppTheme.textSecondary)),
            ),
          ]),
          data: (licenses) {
            if (licenses.isEmpty) {
              return ListView(children: [
                const SizedBox(height: 80),
                const Icon(Icons.workspace_premium_outlined,
                    size: 56, color: AppTheme.textSecondary),
                const SizedBox(height: 16),
                const Center(
                  child: Text("You don't hold any licenses yet.",
                      style: TextStyle(
                          color: AppTheme.textPrimary, fontSize: 16)),
                ),
                const SizedBox(height: 8),
                Center(
                  child: TextButton(
                    onPressed: () => context.go('/licenses'),
                    child: const Text('Browse the marketplace'),
                  ),
                ),
              ]);
            }
            return ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: licenses.length,
              itemBuilder: (context, i) => _LicenseCard(license: licenses[i]),
            );
          },
        ),
      ),
    );
  }
}

class _LicenseCard extends StatelessWidget {
  final Map<String, dynamic> license;
  const _LicenseCard({required this.license});

  String _expiryLabel() {
    final exp = license['expiration_date'];
    if (exp == null) return 'Perpetual';
    final d = DateTime.tryParse(exp.toString());
    if (d == null) return exp.toString();
    final days = d.difference(DateTime.now()).inDays;
    if (days < 0) return 'Expired';
    if (days == 0) return 'Expires today';
    if (days <= 60) return 'Expires in $days day${days == 1 ? '' : 's'}';
    return 'Expires ${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final listing = license['lkn_listings'] as Map<String, dynamic>?;
    final tier = license['lkn_license_tiers'] as Map<String, dynamic>?;
    final licenseId = license['license_id'] as String? ?? '';
    final status = license['status'] as String?;
    final imageUrl = listing?['licensor_image_url'] as String?;
    final statusColor = LicensingFormat.statusColor(status);

    return Container(
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 24,
                backgroundColor: AppTheme.primary.withValues(alpha: 0.2),
                backgroundImage:
                    imageUrl != null ? NetworkImage(imageUrl) : null,
                child: imageUrl == null
                    ? const Icon(Icons.person, color: AppTheme.primary)
                    : null,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(listing?['licensor_display_name'] as String? ?? '—',
                        style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 16,
                            fontWeight: FontWeight.bold)),
                    Text(tier?['tier_name'] as String? ?? '',
                        style: const TextStyle(
                            color: AppTheme.textSecondary, fontSize: 13)),
                  ],
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: statusColor.withValues(alpha: 0.5)),
                ),
                child: Text(LicensingFormat.statusLabel(status),
                    style: TextStyle(
                        color: statusColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w700)),
              ),
            ],
          ),
          const SizedBox(height: 14),
          // License ID (copyable)
          InkWell(
            onTap: () {
              Clipboard.setData(ClipboardData(text: licenseId));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('License ID copied')),
              );
            },
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              decoration: BoxDecoration(
                color: AppTheme.background,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: AppTheme.cardBorder),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: Text(licenseId,
                        style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontFamily: 'monospace',
                            fontSize: 13,
                            fontWeight: FontWeight.w600)),
                  ),
                  const Icon(Icons.copy,
                      size: 14, color: AppTheme.textSecondary),
                ],
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.schedule,
                  size: 14, color: AppTheme.textSecondary),
              const SizedBox(width: 6),
              Text(_expiryLabel(),
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 13)),
              if (license['is_simulated'] == true) ...[
                const SizedBox(width: 12),
                const Icon(Icons.science_outlined,
                    size: 14, color: AppTheme.secondary),
                const SizedBox(width: 4),
                const Text('Simulated',
                    style: TextStyle(color: AppTheme.secondary, fontSize: 12)),
              ],
            ],
          ),
          const SizedBox(height: 14),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: () => context.push('/license/$licenseId'),
                  icon: const Icon(Icons.open_in_new, size: 16),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: AppTheme.primary,
                    side: BorderSide(
                        color: AppTheme.primary.withValues(alpha: 0.5)),
                  ),
                  label: const Text('Public record'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: status == 'active'
                      ? () => _syncToArena(context, licenseId)
                      : null,
                  icon: const Icon(Icons.sync, size: 16),
                  label: const Text('Sync to Arena'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _syncToArena(BuildContext context, String licenseId) {
    // Deep link into the N.O.R.A. Arena mobile app (doc6). The app verifies the
    // license against api.noraplatforms.com/v1/verify on receipt.
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppTheme.surface,
        title: const Text('Sync to Arena App',
            style: TextStyle(color: AppTheme.textPrimary, fontSize: 18)),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Open the N.O.R.A. Arena app and add this license token:',
              style: TextStyle(color: AppTheme.textSecondary),
            ),
            const SizedBox(height: 12),
            SelectableText(
              'noraarena://license/$licenseId',
              style: const TextStyle(
                  color: AppTheme.primary,
                  fontFamily: 'monospace',
                  fontWeight: FontWeight.w600),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(
                  ClipboardData(text: 'noraarena://license/$licenseId'));
              Navigator.of(ctx).pop();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('Sync link copied')),
              );
            },
            child: const Text('Copy link'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Done'),
          ),
        ],
      ),
    );
  }
}
