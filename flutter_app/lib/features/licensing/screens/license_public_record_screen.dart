import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import '../../../core/theme/app_theme.dart';
import '../licensing_format.dart';
import '../providers/licensing_providers.dart';
import '../../../core/widgets/n_back_button.dart';

/// Public, no-auth page for any license. The human-readable equivalent of the
/// verification API response — no PII. Served at /license/:licenseId.
class LicensePublicRecordScreen extends ConsumerWidget {
  final String licenseId;
  const LicensePublicRecordScreen({super.key, required this.licenseId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final recordAsync = ref.watch(publicLicenseRecordProvider(licenseId));

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        leading: const NBackButton(fallback: '/licenses'),
        backgroundColor: AppTheme.surface,
        title: const Text('License Record',
            style: TextStyle(color: AppTheme.textPrimary)),
        iconTheme: const IconThemeData(color: AppTheme.textPrimary),
      ),
      body: recordAsync.when(
        loading: () => const Center(
            child: CircularProgressIndicator(color: AppTheme.primary)),
        error: (e, _) => _CenterMessage(
          icon: Icons.error_outline,
          title: 'Could not load this record',
          subtitle: e.toString(),
        ),
        data: (record) {
          if (record == null) {
            return const _CenterMessage(
              icon: Icons.search_off,
              title: 'License not found',
              subtitle:
                  'No public record exists for this license ID. Check the ID and try again.',
            );
          }
          return _RecordBody(licenseId: licenseId, record: record);
        },
      ),
    );
  }
}

class _RecordBody extends StatelessWidget {
  final String licenseId;
  final Map<String, dynamic> record;
  const _RecordBody({required this.licenseId, required this.record});

  @override
  Widget build(BuildContext context) {
    final status = record['license_status'] as String?;
    final purposes =
        (record['permitted_purposes'] as List?)?.cast<String>() ?? const [];
    final restrictions =
        (record['content_restrictions'] as List?)?.cast<String>() ?? const [];
    final aiAllowed = record['ai_use_allowed'] == true;
    final imageUrl = record['licensor_image_url'] as String?;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            // ── Header card ──
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: AppTheme.surface,
                borderRadius: BorderRadius.circular(16),
                border: Border.all(color: AppTheme.cardBorder),
              ),
              child: Column(
                children: [
                  Row(
                    children: [
                      CircleAvatar(
                        radius: 32,
                        backgroundColor: AppTheme.primary.withValues(alpha: 0.2),
                        backgroundImage:
                            imageUrl != null ? NetworkImage(imageUrl) : null,
                        child: imageUrl == null
                            ? const Icon(Icons.person,
                                color: AppTheme.primary, size: 32)
                            : null,
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              record['licensor_display_name'] as String? ?? '',
                              style: const TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              LicensingFormat.categoryLabel(
                                  record['listing_category'] as String?),
                              style: const TextStyle(
                                  color: AppTheme.textSecondary, fontSize: 13),
                            ),
                          ],
                        ),
                      ),
                      _StatusBadge(status: status),
                    ],
                  ),
                  const SizedBox(height: 16),
                  _LicenseIdRow(licenseId: licenseId),
                ],
              ),
            ),
            const SizedBox(height: 16),

            // ── Key facts ──
            _FactCard(rows: [
              _Fact('Effective date', _date(record['effective_date'])),
              _Fact(
                  'Expiration',
                  record['expiration_date'] == null
                      ? 'Perpetual'
                      : _date(record['expiration_date'])),
              _Fact('Territory',
                  _territoryLabel(record['territory'] as String?)),
              _Fact('AI use', aiAllowed ? 'Permitted' : 'Not permitted'),
            ]),
            const SizedBox(height: 16),

            _ChipSection(
              title: 'Permitted uses',
              emptyText: 'No specific uses listed.',
              items: purposes,
              color: AppTheme.success,
              icon: Icons.check_circle_outline,
            ),
            const SizedBox(height: 16),
            _ChipSection(
              title: 'Content restrictions',
              emptyText: 'No restrictions listed.',
              items: restrictions,
              color: AppTheme.danger,
              icon: Icons.block,
            ),
            const SizedBox(height: 24),

            _ApiSnippet(licenseId: licenseId),
            const SizedBox(height: 16),
            Text(
              'Last verified ${_dateTime(record['last_verified_at'])}',
              textAlign: TextAlign.center,
              style:
                  const TextStyle(color: AppTheme.textSecondary, fontSize: 12),
            ),
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  static String _date(dynamic v) {
    if (v == null) return '—';
    final d = DateTime.tryParse(v.toString());
    if (d == null) return v.toString();
    return '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
  }

  static String _dateTime(dynamic v) {
    final d = v == null ? null : DateTime.tryParse(v.toString());
    if (d == null) return '—';
    return _date(v);
  }

  static String _territoryLabel(String? t) {
    switch (t) {
      case 'worldwide':
        return 'Worldwide';
      case 'us_only':
        return 'United States only';
      case 'eu_only':
        return 'European Union only';
      case 'specific':
        return 'Specific countries';
      default:
        return t ?? '—';
    }
  }
}

class _LicenseIdRow extends StatelessWidget {
  final String licenseId;
  const _LicenseIdRow({required this.licenseId});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Row(
        children: [
          const Icon(Icons.verified_user, color: AppTheme.primary, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: SelectableText(
              licenseId,
              style: const TextStyle(
                color: AppTheme.textPrimary,
                fontFamily: 'monospace',
                fontSize: 14,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
          IconButton(
            tooltip: 'Copy license ID',
            icon: const Icon(Icons.copy, size: 16, color: AppTheme.textSecondary),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: licenseId));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('License ID copied')),
              );
            },
          ),
        ],
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String? status;
  const _StatusBadge({required this.status});

  @override
  Widget build(BuildContext context) {
    final color = LicensingFormat.statusColor(status);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        LicensingFormat.statusLabel(status),
        style: TextStyle(
            color: color, fontSize: 12, fontWeight: FontWeight.w700),
      ),
    );
  }
}

class _FactCard extends StatelessWidget {
  final List<_Fact> rows;
  const _FactCard({required this.rows});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        children: rows
            .map((f) => Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        flex: 2,
                        child: Text(f.label,
                            style: const TextStyle(
                                color: AppTheme.textSecondary, fontSize: 14)),
                      ),
                      Expanded(
                        flex: 3,
                        child: Text(f.value,
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                                color: AppTheme.textPrimary,
                                fontSize: 14,
                                fontWeight: FontWeight.w600)),
                      ),
                    ],
                  ),
                ))
            .toList(),
      ),
    );
  }
}

class _Fact {
  final String label;
  final String value;
  const _Fact(this.label, this.value);
}

class _ChipSection extends StatelessWidget {
  final String title;
  final String emptyText;
  final List<String> items;
  final Color color;
  final IconData icon;
  const _ChipSection({
    required this.title,
    required this.emptyText,
    required this.items,
    required this.color,
    required this.icon,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title,
              style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 16,
                  fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          if (items.isEmpty)
            Text(emptyText,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 13))
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: items
                  .map((p) => Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        decoration: BoxDecoration(
                          color: color.withValues(alpha: 0.12),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(icon, size: 14, color: color),
                            const SizedBox(width: 6),
                            Text(p,
                                style: TextStyle(
                                    color: color,
                                    fontSize: 13,
                                    fontWeight: FontWeight.w500)),
                          ],
                        ),
                      ))
                  .toList(),
            ),
        ],
      ),
    );
  }
}

class _ApiSnippet extends StatelessWidget {
  final String licenseId;
  const _ApiSnippet({required this.licenseId});

  @override
  Widget build(BuildContext context) {
    final snippet =
        'curl "https://api.noraplatforms.com/v1/verify?license_id=$licenseId" \\\n'
        '  -H "X-NORA-API-Key: YOUR_LKN_API_KEY"';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.background,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.terminal, size: 16, color: AppTheme.secondary),
              const SizedBox(width: 8),
              const Expanded(
                child: Text('Verify this license via API',
                    style: TextStyle(
                        color: AppTheme.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600)),
              ),
              IconButton(
                tooltip: 'Copy',
                icon: const Icon(Icons.copy,
                    size: 16, color: AppTheme.textSecondary),
                onPressed: () {
                  Clipboard.setData(ClipboardData(text: snippet));
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Snippet copied')),
                  );
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          SelectableText(
            snippet,
            style: const TextStyle(
              color: AppTheme.secondary,
              fontFamily: 'monospace',
              fontSize: 12.5,
              height: 1.5,
            ),
          ),
        ],
      ),
    );
  }
}

class _CenterMessage extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  const _CenterMessage({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: AppTheme.textSecondary),
            const SizedBox(height: 16),
            Text(title,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            Text(subtitle,
                textAlign: TextAlign.center,
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 14)),
            const SizedBox(height: 24),
            TextButton(
              onPressed: () => context.go('/licenses'),
              child: const Text('Browse the marketplace'),
            ),
          ],
        ),
      ),
    );
  }
}
