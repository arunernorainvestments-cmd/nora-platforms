import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import '../../../core/theme/app_theme.dart';
import '../models/poll_models.dart';
import '../providers/poll_providers.dart';
import '../../../core/utils/device_fingerprint.dart';
import '../../../core/widgets/n_back_button.dart';

class PollScreen extends ConsumerStatefulWidget {
  final String pollId;
  final bool isEmbed;

  const PollScreen({super.key, required this.pollId, this.isEmbed = false});

  @override
  ConsumerState<PollScreen> createState() => _PollScreenState();
}

class _PollScreenState extends ConsumerState<PollScreen> {
  String? _votedOptionId;
  bool _isVoting = false;
  Timer? _countdownTimer;
  Duration _remaining = Duration.zero;

  @override
  void dispose() {
    _countdownTimer?.cancel();
    super.dispose();
  }

  void _startCountdown(DateTime closesAt) {
    _updateRemaining(closesAt);
    _countdownTimer?.cancel();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      _updateRemaining(closesAt);
    });
  }

  void _updateRemaining(DateTime closesAt) {
    final diff = closesAt.difference(DateTime.now());
    setState(() => _remaining = diff.isNegative ? Duration.zero : diff);
  }

  String _formatCountdown() {
    final h = _remaining.inHours;
    final m = _remaining.inMinutes % 60;
    final s = _remaining.inSeconds % 60;
    if (h > 0) return '${h}h ${m}m';
    if (m > 0) return '${m}m ${s}s';
    return '${s}s';
  }

  Future<void> _submitVote(BuildContext context, String optionId) async {
    if (_isVoting) return;
    setState(() {
      _isVoting = true;
      _votedOptionId = optionId;
    });

    try {
      final fingerprint = await getDeviceFingerprint();
      final body = {
        'poll_id': widget.pollId,
        'option_id': optionId,
        if (fingerprint != null) 'device_fingerprint': fingerprint,
      };

      await Supabase.instance.client.functions.invoke(
        'poll-vote',
        body: body,
      );

      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Vote recorded!')),
      );
      ref.invalidate(hasVotedProvider(widget.pollId));
    } catch (e) {
      if (!context.mounted) return;
      setState(() => _votedOptionId = null);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Vote failed: $e')),
      );
    } finally {
      if (mounted) setState(() => _isVoting = false);
    }
  }

  void _copyShareLink(BuildContext context) {
    final url = 'https://noraplatforms.com/poll/${widget.pollId}';
    Clipboard.setData(ClipboardData(text: url));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Link copied to clipboard')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final optionsAsync = ref.watch(pollOptionsStreamProvider(widget.pollId));
    final hasVotedAsync = ref.watch(hasVotedProvider(widget.pollId));
    final currentOpenPoll = ref.watch(currentOpenPollProvider);

    WeeklyPoll? poll;
    currentOpenPoll.whenData((p) {
      if (p?.id == widget.pollId) {
        poll = p;
        if (p != null && _remaining == Duration.zero) {
          _startCountdown(p.closesAt);
        }
      }
    });

    return Scaffold(
      backgroundColor: AppTheme.background,
      appBar: widget.isEmbed
          ? null
          : AppBar(
              leading: const NBackButton(),
              backgroundColor: AppTheme.surface,
              title: const Text('Weekly Poll',
                  style: TextStyle(color: AppTheme.textPrimary)),
              iconTheme: const IconThemeData(color: AppTheme.textPrimary),
              actions: [
                IconButton(
                  icon: const Icon(Icons.share, color: AppTheme.textPrimary),
                  tooltip: 'Copy share link',
                  onPressed: () => _copyShareLink(context),
                ),
              ],
            ),
      body: optionsAsync.when(
        data: (options) {
          final hasVoted =
              hasVotedAsync.value ?? false || _votedOptionId != null;
          final isOpen = poll?.isOpen ?? false;
          final totalVotes = options.fold<double>(
              0, (sum, o) => sum + o.weightedVoteTotal);

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (poll != null)
                _PollHeader(
                  poll: poll!,
                  countdown: isOpen ? _formatCountdown() : null,
                ),
              Expanded(
                child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: options.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final opt = options[i];
                    final pct = totalVotes > 0
                        ? opt.weightedVoteTotal / totalVotes
                        : 0.0;
                    final isSelected = _votedOptionId == opt.id ||
                        (hasVoted && opt.id == _votedOptionId);
                    return _PollOptionTile(
                      option: opt,
                      pct: pct,
                      rank: i + 1,
                      showResults: hasVoted || !isOpen,
                      isSelected: isSelected,
                      canVote: isOpen && !hasVoted && !_isVoting,
                      onVote: () => _submitVote(context, opt.id),
                    );
                  },
                ),
              ),
              if (!widget.isEmbed)
                _PollFooter(
                  totalVotes: options.fold<int>(
                      0, (sum, o) => sum + o.rawVoteCount),
                  isOpen: isOpen,
                  onShare: () => _copyShareLink(context),
                ),
            ],
          );
        },
        loading: () => const Center(
            child: CircularProgressIndicator(color: AppTheme.primary)),
        error: (e, _) => Center(
          child: Text('Error: $e',
              style: const TextStyle(color: AppTheme.danger)),
        ),
      ),
    );
  }
}

class _PollHeader extends StatelessWidget {
  final WeeklyPoll poll;
  final String? countdown;

  const _PollHeader({required this.poll, this.countdown});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      color: AppTheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (countdown != null) ...[
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppTheme.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.timer, color: AppTheme.primary, size: 14),
                  const SizedBox(width: 4),
                  Text('Closes in $countdown',
                      style: const TextStyle(
                          color: AppTheme.primary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600)),
                ],
              ),
            ),
            const SizedBox(height: 6),
          ],
          Text(poll.title,
              style: const TextStyle(
                  color: AppTheme.textPrimary,
                  fontSize: 18,
                  fontWeight: FontWeight.bold)),
          if (poll.description != null && poll.description!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(poll.description!,
                  style: const TextStyle(
                      color: AppTheme.textSecondary, fontSize: 13)),
            ),
        ],
      ),
    );
  }
}

class _PollOptionTile extends StatelessWidget {
  final PollOption option;
  final double pct;
  final int rank;
  final bool showResults;
  final bool isSelected;
  final bool canVote;
  final VoidCallback onVote;

  const _PollOptionTile({
    required this.option,
    required this.pct,
    required this.rank,
    required this.showResults,
    required this.isSelected,
    required this.canVote,
    required this.onVote,
  });

  @override
  Widget build(BuildContext context) {
    final rankColor = switch (rank) {
      1 => const Color(0xFFFFD700),
      2 => const Color(0xFFC0C0C0),
      3 => const Color(0xFFCD7F32),
      _ => AppTheme.textSecondary,
    };

    return GestureDetector(
      onTap: canVote ? onVote : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          color: isSelected
              ? AppTheme.primary.withValues(alpha: 0.15)
              : AppTheme.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? AppTheme.primary : AppTheme.cardBorder,
            width: isSelected ? 1.5 : 1,
          ),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: rankColor.withValues(alpha: 0.15),
                    ),
                    child: Center(
                      child: Text('$rank',
                          style: TextStyle(
                              color: rankColor,
                              fontWeight: FontWeight.bold,
                              fontSize: 12)),
                    ),
                  ),
                  const SizedBox(width: 10),
                  if (option.imageUrl != null)
                    CircleAvatar(
                      radius: 16,
                      backgroundImage: NetworkImage(option.imageUrl!),
                    ),
                  if (option.imageUrl != null) const SizedBox(width: 8),
                  Expanded(
                    child: Text(option.displayName,
                        style: const TextStyle(
                            color: AppTheme.textPrimary,
                            fontWeight: FontWeight.w600,
                            fontSize: 14)),
                  ),
                  if (option.archetype != null)
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: AppTheme.primary.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        option.archetype!.toUpperCase(),
                        style: const TextStyle(
                            color: AppTheme.primary,
                            fontSize: 10,
                            fontWeight: FontWeight.w600),
                      ),
                    ),
                  if (isSelected)
                    const Padding(
                      padding: EdgeInsets.only(left: 8),
                      child: Icon(Icons.check_circle,
                          color: AppTheme.primary, size: 16),
                    ),
                ],
              ),
              if (showResults) ...[
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: LinearProgressIndicator(
                        value: pct,
                        backgroundColor: AppTheme.cardBorder,
                        color: rank == 1 ? rankColor : AppTheme.primary,
                        minHeight: 6,
                        borderRadius: BorderRadius.circular(3),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text('${(pct * 100).toStringAsFixed(1)}%',
                        style: const TextStyle(
                            color: AppTheme.textSecondary,
                            fontSize: 12,
                            fontWeight: FontWeight.w600)),
                  ],
                ),
                const SizedBox(height: 2),
                Text('${option.rawVoteCount} votes',
                    style: const TextStyle(
                        color: AppTheme.textSecondary, fontSize: 11)),
              ] else ...[
                const SizedBox(height: 4),
                const Text('Tap to vote',
                    style: TextStyle(
                        color: AppTheme.textSecondary, fontSize: 11)),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _PollFooter extends StatelessWidget {
  final int totalVotes;
  final bool isOpen;
  final VoidCallback onShare;

  const _PollFooter({
    required this.totalVotes,
    required this.isOpen,
    required this.onShare,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      color: AppTheme.surface,
      child: Row(
        children: [
          Text('$totalVotes votes cast',
              style: const TextStyle(
                  color: AppTheme.textSecondary, fontSize: 12)),
          const Spacer(),
          if (!isOpen)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: AppTheme.textSecondary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: const Text('Voting closed',
                  style: TextStyle(
                      color: AppTheme.textSecondary, fontSize: 12)),
            ),
          const SizedBox(width: 8),
          TextButton.icon(
            onPressed: onShare,
            icon: const Icon(Icons.link, size: 14, color: AppTheme.primary),
            label: const Text('Share',
                style: TextStyle(color: AppTheme.primary, fontSize: 13)),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            ),
          ),
        ],
      ),
    );
  }
}
