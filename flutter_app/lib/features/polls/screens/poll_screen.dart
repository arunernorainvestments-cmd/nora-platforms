import 'package:flutter/material.dart';

// Doc 3 — Weekly Polls (weekly_polls table).
// Full implementation pending Doc 3 session.
class PollScreen extends StatelessWidget {
  final String pollId;
  final bool isEmbed;

  const PollScreen({super.key, required this.pollId, this.isEmbed = false});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: isEmbed ? null : AppBar(title: const Text('Poll')),
      body: const Center(child: Text('Coming soon')),
    );
  }
}
