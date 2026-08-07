import 'package:flutter/material.dart';

import '../../assistant/assistant_service.dart';

/// Small phase glyph: a pulsing ring while [phase] is listening, a static
/// ring (no [AnimationController] ticking) otherwise or whenever [lowFx] is
/// true. Colors follow the phase so the glyph reads at a glance from across
/// a room: grey when off, outline when idle, primary while listening or
/// responding, secondary while acting.
///
/// No third-party animation packages — a single [AnimationController]
/// repeats a 0-1 ramp that drives the ring's scale and fade.
class ListeningIndicator extends StatefulWidget {
  const ListeningIndicator({
    super.key,
    required this.phase,
    required this.lowFx,
    this.size = 96,
  });

  final AssistantPhase phase;

  /// When true, animations are stripped for weak/old hardware.
  final bool lowFx;

  final double size;

  @override
  State<ListeningIndicator> createState() => _ListeningIndicatorState();
}

class _ListeningIndicatorState extends State<ListeningIndicator>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1400),
  );

  bool get _shouldAnimate =>
      widget.phase == AssistantPhase.listening && !widget.lowFx;

  @override
  void initState() {
    super.initState();
    _syncAnimation();
  }

  @override
  void didUpdateWidget(covariant ListeningIndicator oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.phase != widget.phase || oldWidget.lowFx != widget.lowFx) {
      _syncAnimation();
    }
  }

  void _syncAnimation() {
    if (_shouldAnimate) {
      if (!_controller.isAnimating) _controller.repeat();
    } else {
      _controller.stop();
      _controller.value = 0;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Color _color(ColorScheme scheme) => switch (widget.phase) {
        AssistantPhase.off => scheme.outline,
        AssistantPhase.idle => scheme.outline,
        AssistantPhase.listening => scheme.primary,
        AssistantPhase.acting => scheme.secondary,
        AssistantPhase.responding => scheme.primary,
      };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = _color(scheme);
    final showRing = widget.phase == AssistantPhase.listening;

    return SizedBox(
      width: widget.size,
      height: widget.size,
      child: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          final t = _shouldAnimate ? _controller.value : 0.45;
          final ringScale = 0.6 + (0.4 * t);
          final ringAlpha = showRing
              ? (_shouldAnimate ? (1 - t) * 0.6 : 0.35)
              : 0.0;
          return Stack(
            alignment: Alignment.center,
            children: [
              if (showRing)
                Transform.scale(
                  scale: ringScale,
                  child: Container(
                    width: widget.size,
                    height: widget.size,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: color.withValues(alpha: ringAlpha),
                        width: 3,
                      ),
                    ),
                  ),
                ),
              Container(
                width: widget.size * 0.55,
                height: widget.size * 0.55,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: color.withValues(alpha: 0.18),
                  border: Border.all(color: color, width: 2),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
