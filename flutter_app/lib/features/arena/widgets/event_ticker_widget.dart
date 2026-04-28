import 'package:flutter/material.dart';
import '../../../core/theme/app_theme.dart';
import '../models/arena_event.dart';
import '../models/arena_match.dart';

class EventTickerWidget extends StatefulWidget {
  final List<ArenaEvent> events;
  final ArenaMatch match;

  const EventTickerWidget({
    super.key,
    required this.events,
    required this.match,
  });

  @override
  State<EventTickerWidget> createState() => _EventTickerWidgetState();
}

class _EventTickerWidgetState extends State<EventTickerWidget> {
  List<ArenaEvent> _prev = [];

  @override
  Widget build(BuildContext context) {
    final events = widget.events;
    _prev = events;

    if (events.isEmpty) {
      return const Center(
        child: Text(
          'No actions yet',
          style: TextStyle(color: AppTheme.textSecondary, fontSize: 11),
        ),
      );
    }

    return ListView.separated(
      reverse: false,
      itemCount: events.length,
      separatorBuilder: (_, __) => const SizedBox(height: 4),
      itemBuilder: (context, i) {
        final e = events[i];
        final isP1 = e.targetId == widget.match.player1Id;
        final targetName = isP1
            ? widget.match.player1Username
            : widget.match.player2Username;
        final accentColor =
            isP1 ? AppTheme.primary : AppTheme.secondary;

        return _TickerRow(
          event: e,
          targetName: targetName,
          accentColor: accentColor,
          isNew: _prev.isEmpty || i < _prev.length && _prev[i].id != e.id,
        );
      },
    );
  }
}

class _TickerRow extends StatefulWidget {
  final ArenaEvent event;
  final String targetName;
  final Color accentColor;
  final bool isNew;

  const _TickerRow({
    required this.event,
    required this.targetName,
    required this.accentColor,
    required this.isNew,
  });

  @override
  State<_TickerRow> createState() => _TickerRowState();
}

class _TickerRowState extends State<_TickerRow>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  late Animation<Offset> _slide;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    _slide = Tween<Offset>(
      begin: const Offset(1.0, 0),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
    _ctrl.forward();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final amount = widget.event.value.toInt();
    return SlideTransition(
      position: _slide,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
        decoration: BoxDecoration(
          color: widget.accentColor.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: widget.accentColor.withValues(alpha: 0.2),
          ),
        ),
        child: Row(
          children: [
            Icon(Icons.bolt, color: widget.accentColor, size: 11),
            const SizedBox(width: 4),
            Expanded(
              child: Text(
                '+$amount → ${widget.targetName}',
                style: TextStyle(
                  color: widget.accentColor,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
