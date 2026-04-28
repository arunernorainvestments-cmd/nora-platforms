import 'package:flutter/material.dart';
import '../models/arena_state_model.dart';

// The beam is a vertical gradient bar that leans toward the losing side.
// Position = fractionP1 (P1 score / total) along the available width.
// When P1 wins → beam shifts right (toward P2/loser).
// When equal  → beam centered.

class CenterBeamWidget extends StatelessWidget {
  final ArenaStateModel state;
  final Color colorP1;
  final Color colorP2;

  const CenterBeamWidget({
    super.key,
    required this.state,
    required this.colorP1,
    required this.colorP2,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 40,
      child: TweenAnimationBuilder<double>(
        tween: Tween(end: state.fractionP1),
        duration: const Duration(milliseconds: 3000),
        curve: Curves.easeInOut,
        builder: (context, fraction, _) {
          return Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Container(
                width: 4,
                height: 80,
                margin: EdgeInsets.only(
                  left: (fraction * 32).clamp(0, 32),
                  right: ((1 - fraction) * 32).clamp(0, 32),
                ),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(2),
                  gradient: LinearGradient(
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    colors: [
                      colorP1.withValues(alpha: 0.8),
                      Colors.white.withValues(alpha: 0.9),
                      colorP2.withValues(alpha: 0.8),
                    ],
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.white.withValues(alpha: 0.3),
                      blurRadius: 8,
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
