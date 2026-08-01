import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../../core/theme/app_theme.dart';
import '../services/reveal_share.dart';

/// The share step of a mint (Standard Playset spec S4.1 — the viral atom).
///
/// "My post became a playable card" is the shareable unit, so the product hands
/// it over finished: a 9:16 reveal clip, a caption, and a join link carrying the
/// minter's referral code. One tap to the native share sheet where the browser
/// has one, copy-link everywhere else. Never gated, never a dead end — if the
/// composer is unavailable the sheet still shares the link.
Future<void> showRevealShareSheet(BuildContext context, String chitId) {
  return showDialog<void>(
    context: context,
    builder: (_) => _RevealShareDialog(chitId: chitId),
  );
}

class _RevealShareDialog extends StatefulWidget {
  const _RevealShareDialog({required this.chitId});
  final String chitId;

  @override
  State<_RevealShareDialog> createState() => _RevealShareDialogState();
}

class _RevealShareDialogState extends State<_RevealShareDialog> {
  RevealShare? _share;
  String? _error;
  bool _copied = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final s = await RevealShareService.compose(widget.chitId);
      if (mounted) setState(() => _share = s);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _share_() async {
    final s = _share;
    if (s == null) return;
    final shared = await RevealShareService.nativeShare(s);
    if (!shared) await _copy();
  }

  Future<void> _copy() async {
    final s = _share;
    if (s == null) return;
    await RevealShareService.copyLink(s);
    if (mounted) setState(() => _copied = true);
  }

  Future<void> _open() async {
    final url = _share?.assetUrl;
    if (url == null) return;
    await launchUrl(Uri.parse(url), webOnlyWindowName: '_blank');
  }

  @override
  Widget build(BuildContext context) {
    final s = _share;
    return Dialog(
      backgroundColor: AppTheme.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: const BorderSide(color: AppTheme.cardBorder),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 400),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.ios_share, color: AppTheme.primary, size: 34),
              const SizedBox(height: 10),
              const Text('Show them your card',
                  style: TextStyle(
                      color: AppTheme.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              const Text(
                'Your moment became a playable card. Post the reveal — the link '
                'brings people straight to your card.',
                textAlign: TextAlign.center,
                style: TextStyle(
                    color: AppTheme.textSecondary, fontSize: 12.5, height: 1.5),
              ),
              const SizedBox(height: 16),
              if (_error != null)
                Text('Could not prepare the reveal — $_error',
                    textAlign: TextAlign.center,
                    style: const TextStyle(
                        color: AppTheme.danger, fontSize: 12))
              else if (s == null)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 18),
                  child: Column(children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 10),
                    Text('Putting your reveal together…',
                        style: TextStyle(
                            color: AppTheme.textSecondary, fontSize: 12)),
                  ]),
                )
              else ...[
                if (!s.ready)
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: AppTheme.surfaceLight,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Text(
                      'The reveal clip is still being made. You can share your '
                      'link now and post the clip later.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                          color: AppTheme.textSecondary, fontSize: 12),
                    ),
                  ),
                const SizedBox(height: 14),
                SelectableText(
                  s.shareText,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                      color: AppTheme.textPrimary, fontSize: 12.5, height: 1.5),
                ),
                const SizedBox(height: 16),
                Wrap(
                  alignment: WrapAlignment.center,
                  spacing: 10,
                  runSpacing: 8,
                  children: [
                    FilledButton.icon(
                      onPressed: _share_,
                      icon: const Icon(Icons.ios_share, size: 18),
                      label: Text(RevealShareService.canNativeShare
                          ? 'Share'
                          : 'Copy link'),
                    ),
                    if (RevealShareService.canNativeShare)
                      OutlinedButton.icon(
                        onPressed: _copy,
                        icon: Icon(
                            _copied ? Icons.check : Icons.link,
                            size: 18),
                        label: Text(_copied ? 'Copied' : 'Copy link'),
                      ),
                    if (s.ready)
                      OutlinedButton.icon(
                        onPressed: _open,
                        icon: const Icon(Icons.download_outlined, size: 18),
                        label: const Text('Get the clip'),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 10),
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Done',
                    style: TextStyle(color: AppTheme.textSecondary)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
