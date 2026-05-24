import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import '../../../core/theme/app_theme.dart';
import '../providers/campaigns_providers.dart';

class CampaignUpdatesScreen extends ConsumerStatefulWidget {
  final String campaignId;
  final bool isCreator;

  const CampaignUpdatesScreen({
    super.key,
    required this.campaignId,
    required this.isCreator,
  });

  @override
  ConsumerState<CampaignUpdatesScreen> createState() =>
      _CampaignUpdatesScreenState();
}

class _CampaignUpdatesScreenState extends ConsumerState<CampaignUpdatesScreen> {
  void _showPostSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: AppTheme.surface,
      shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (_) => _PostUpdateSheet(
        campaignId: widget.campaignId,
        onPosted: () {
          ref.invalidate(campaignUpdatesProvider(widget.campaignId));
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final updatesAsync = ref.watch(campaignUpdatesProvider(widget.campaignId));

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: AppBar(
        backgroundColor: AppTheme.surface,
        title: const Text('Campaign Updates'),
      ),
      floatingActionButton: widget.isCreator
          ? FloatingActionButton.extended(
              backgroundColor: AppTheme.secondary,
              onPressed: _showPostSheet,
              icon: const Icon(Icons.edit_outlined, color: Colors.black87),
              label: const Text('Post Update',
                  style: TextStyle(
                      color: Colors.black87, fontWeight: FontWeight.w700)),
            )
          : null,
      body: updatesAsync.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (e, _) => const Center(
          child: Text('Failed to load updates',
              style: TextStyle(color: AppTheme.textSecondary)),
        ),
        data: (list) {
          if (list.isEmpty) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(40),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.campaign_outlined,
                        size: 48, color: AppTheme.textSecondary),
                    const SizedBox(height: 16),
                    const Text('No updates yet',
                        style: TextStyle(
                            color: AppTheme.textPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w700)),
                    const SizedBox(height: 8),
                    Text(
                      widget.isCreator
                          ? 'Post an update to keep your backers informed.'
                          : 'The creator has not posted any updates yet.',
                      textAlign: TextAlign.center,
                      style: const TextStyle(
                          color: AppTheme.textSecondary, height: 1.5),
                    ),
                  ],
                ),
              ),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.all(20),
            itemCount: list.length,
            separatorBuilder: (_, __) => const SizedBox(height: 12),
            itemBuilder: (context, i) => _UpdateCard(update: list[i]),
          );
        },
      ),
    );
  }
}

class _UpdateCard extends StatelessWidget {
  final CampaignUpdate update;
  const _UpdateCard({required this.update});

  Color get _typeColor {
    switch (update.updateType) {
      case 'milestone':
        return const Color(0xFFFFD700);
      case 'urgent':
        return AppTheme.danger;
      case 'proposal':
        return AppTheme.primary;
      case 'revenue':
        return AppTheme.success;
      default:
        return AppTheme.secondary;
    }
  }

  IconData get _typeIcon {
    switch (update.updateType) {
      case 'milestone':
        return Icons.emoji_events_outlined;
      case 'urgent':
        return Icons.priority_high;
      case 'proposal':
        return Icons.how_to_vote_outlined;
      case 'revenue':
        return Icons.attach_money;
      default:
        return Icons.campaign_outlined;
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateFmt = DateFormat('MMM d, yyyy');

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppTheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppTheme.cardBorder),
      ),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 32,
            height: 32,
            decoration: BoxDecoration(
              color: _typeColor.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(_typeIcon, color: _typeColor, size: 16),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(update.title,
                style: const TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w700)),
          ),
          if (update.publishedAt != null)
            Text(dateFmt.format(update.publishedAt!),
                style: const TextStyle(
                    color: AppTheme.textSecondary, fontSize: 11)),
        ]),
        const SizedBox(height: 10),
        Text(update.body,
            style: const TextStyle(
                color: AppTheme.textSecondary, fontSize: 13, height: 1.6)),
      ]),
    );
  }
}

// ─── Post Update Bottom Sheet ─────────────────────────────────────────────────

class _PostUpdateSheet extends StatefulWidget {
  final String campaignId;
  final VoidCallback onPosted;
  const _PostUpdateSheet({required this.campaignId, required this.onPosted});

  @override
  State<_PostUpdateSheet> createState() => _PostUpdateSheetState();
}

class _PostUpdateSheetState extends State<_PostUpdateSheet> {
  final _formKey = GlobalKey<FormState>();
  final _titleCtrl = TextEditingController();
  final _bodyCtrl = TextEditingController();
  String _type = 'progress';
  bool _submitting = false;

  static const _types = [
    ('progress', 'Progress update'),
    ('milestone', 'Milestone reached'),
    ('proposal', 'Governance proposal'),
    ('revenue', 'Revenue update'),
    ('urgent', 'Urgent notice'),
  ];

  @override
  void dispose() {
    _titleCtrl.dispose();
    _bodyCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _submitting = true);
    try {
      await postCampaignUpdate(
        campaignId: widget.campaignId,
        title: _titleCtrl.text.trim(),
        body: _bodyCtrl.text.trim(),
        updateType: _type,
      );
      if (mounted) {
        widget.onPosted();
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Update posted — all backers notified.'),
            backgroundColor: AppTheme.success,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to post update. Please try again.'),
            backgroundColor: AppTheme.danger,
            behavior: SnackBarBehavior.floating,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 20, 20, 24 + bottom),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 40, height: 4,
              margin: const EdgeInsets.only(bottom: 20),
              decoration: BoxDecoration(
                color: AppTheme.cardBorder,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const Text('Post an Update',
                style: TextStyle(
                    color: AppTheme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w800)),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              value: _type, // ignore: deprecated_member_use
              dropdownColor: AppTheme.surface,
              style: const TextStyle(color: AppTheme.textPrimary),
              decoration: _inputDec('Type'),
              items: _types
                  .map((t) => DropdownMenuItem(
                        value: t.$1,
                        child: Text(t.$2,
                            style: const TextStyle(
                                color: AppTheme.textPrimary)),
                      ))
                  .toList(),
              onChanged: (v) => setState(() => _type = v ?? _type),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _titleCtrl,
              style: const TextStyle(color: AppTheme.textPrimary),
              decoration: _inputDec('Title'),
              maxLength: 120,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _bodyCtrl,
              style: const TextStyle(color: AppTheme.textPrimary),
              decoration: _inputDec('Write your update here…'),
              maxLines: 4,
              validator: (v) =>
                  (v == null || v.trim().isEmpty) ? 'Required' : null,
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: _submitting ? null : _submit,
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppTheme.secondary,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10)),
                ),
                child: _submitting
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.black87),
                      )
                    : const Text('Post Update',
                        style: TextStyle(
                            color: Colors.black87,
                            fontSize: 15,
                            fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
      ),
    );
  }

  InputDecoration _inputDec(String hint) => InputDecoration(
        hintText: hint,
        hintStyle: const TextStyle(color: AppTheme.textSecondary),
        filled: true,
        fillColor: AppTheme.background,
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppTheme.cardBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppTheme.cardBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: const BorderSide(color: AppTheme.primary),
        ),
        counterStyle:
            const TextStyle(color: AppTheme.textSecondary, fontSize: 11),
      );
}
