import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/settings_store.dart';

/// Dims the whole panel during the configured night window, and restores
/// full brightness on any touch.
///
/// A wall-mounted tablet at full brightness is a nightlight. Rather than
/// turning the screen off — which loses the at-a-glance value the panel
/// exists for — this lays a black scrim over it, so the display is still
/// readable in a dark room but no longer lights it.
class NightDimmer extends StatefulWidget {
  const NightDimmer({super.key, required this.child});

  final Widget child;

  @override
  State<NightDimmer> createState() => _NightDimmerState();
}

class _NightDimmerState extends State<NightDimmer> {
  Timer? _tick;
  Timer? _wakeTimer;
  bool _dim = false;
  bool _temporarilyAwake = false;

  @override
  void initState() {
    super.initState();
    _evaluate();
    // Checking once a minute is plenty for an hour-granularity schedule.
    _tick = Timer.periodic(const Duration(minutes: 1), (_) => _evaluate());
  }

  @override
  void dispose() {
    _tick?.cancel();
    _wakeTimer?.cancel();
    super.dispose();
  }

  void _evaluate() {
    if (!mounted) return;
    final shouldDim =
        context.read<SettingsStore>().isDimHour(DateTime.now());
    if (shouldDim != _dim) setState(() => _dim = shouldDim);
  }

  void _wake() {
    if (!_dim) return;
    setState(() => _temporarilyAwake = true);
    _wakeTimer?.cancel();
    _wakeTimer = Timer(const Duration(seconds: 30), () {
      if (mounted) setState(() => _temporarilyAwake = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final dimmed = _dim && !_temporarilyAwake;

    return Stack(
      children: [
        widget.child,
        if (dimmed)
          Positioned.fill(
            child: GestureDetector(
              onTap: _wake,
              // Absorbs the first touch: waking must not also toggle a light.
              behavior: HitTestBehavior.opaque,
              child: const ColoredBox(color: Colors.black87),
            ),
          ),
      ],
    );
  }
}
