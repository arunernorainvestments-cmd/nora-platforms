import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

/// The one canonical back affordance. Most in-app navigation uses context.go()
/// (stack replacement), so Flutter's automatic AppBar back arrow never appears
/// and context.pop() would throw. This pops when a stack exists (push/dialog
/// flows) and otherwise walks "up" to [fallback] — the screen's logical parent
/// — so no page is ever a dead end.
///
/// Usage: `AppBar(leading: NBackButton(fallback: '/battle'), ...)`.
class NBackButton extends StatelessWidget {
  /// Where "back" leads when there is nothing to pop (deep link, go()-based
  /// navigation, page refresh). Defaults to home.
  final String fallback;

  const NBackButton({super.key, this.fallback = '/home'});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      tooltip: 'Back',
      onPressed: () =>
          context.canPop() ? context.pop() : context.go(fallback),
    );
  }
}
