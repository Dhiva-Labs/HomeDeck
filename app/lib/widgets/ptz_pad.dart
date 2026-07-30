import 'package:flutter/material.dart';

import '../connectors/camera/ptz_controller.dart';

/// Directional pad + zoom for ONVIF PTZ cameras. Buttons move while held
/// and stop on release, matching ONVIF's continuous-move model.
class PtzPad extends StatelessWidget {
  const PtzPad({super.key, required this.controller});

  final PtzController controller;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.black54,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _PtzButton(Icons.keyboard_arrow_up, controller, y: 0.5),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _PtzButton(Icons.keyboard_arrow_left, controller, x: -0.5),
                  const SizedBox(width: 44),
                  _PtzButton(Icons.keyboard_arrow_right, controller, x: 0.5),
                ],
              ),
              _PtzButton(Icons.keyboard_arrow_down, controller, y: -0.5),
            ],
          ),
          const SizedBox(width: 16),
          Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _PtzButton(Icons.zoom_in, controller, z: 0.5),
              const SizedBox(height: 8),
              _PtzButton(Icons.zoom_out, controller, z: -0.5),
            ],
          ),
        ],
      ),
    );
  }
}

class _PtzButton extends StatelessWidget {
  const _PtzButton(this.icon, this.controller,
      {this.x = 0, this.y = 0, this.z = 0});

  final IconData icon;
  final PtzController controller;
  final double x;
  final double y;
  final double z;

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => controller.move(x: x, y: y, z: z),
      onPointerUp: (_) => controller.stop(),
      onPointerCancel: (_) => controller.stop(),
      child: Container(
        width: 44,
        height: 44,
        margin: const EdgeInsets.all(2),
        decoration: BoxDecoration(
          color: Colors.white24,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Icon(icon, color: Colors.white),
      ),
    );
  }
}
