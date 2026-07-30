import 'package:easy_onvif/onvif.dart';
import 'package:easy_onvif/shared.dart';
import 'package:flutter/foundation.dart';

import '../../models/camera.dart';

/// Drives ONVIF continuous PTZ for one camera. Connects lazily on the first
/// command and reuses the session for the rest of the screen's life.
class PtzController {
  PtzController(this.camera);

  final Camera camera;
  Onvif? _onvif;
  bool _connecting = false;

  bool get available => camera.supportsPtz;

  Future<Onvif?> _ensureConnected() async {
    if (_onvif != null) return _onvif;
    if (_connecting || !available) return null;
    _connecting = true;
    try {
      _onvif = await Onvif.connect(
        host: camera.onvifHost!,
        username: camera.username,
        password: camera.password,
      );
    } catch (e) {
      debugPrint('PTZ: connect failed: $e');
    } finally {
      _connecting = false;
    }
    return _onvif;
  }

  /// Start moving. x: pan (-1..1), y: tilt (-1..1), z: zoom (-1..1).
  /// Keeps moving until [stop] is called — wire to press/release.
  Future<void> move({double x = 0, double y = 0, double z = 0}) async {
    final onvif = await _ensureConnected();
    if (onvif == null) return;
    try {
      await onvif.ptz.continuousMove(
        camera.onvifProfileToken!,
        velocity: PtzSpeed(
          panTilt: (x != 0 || y != 0) ? Vector2D(x: x, y: y) : null,
          zoom: z != 0 ? Vector1D(x: z) : null,
        ),
      );
    } catch (e) {
      debugPrint('PTZ: move failed: $e');
    }
  }

  Future<void> stop() async {
    final onvif = _onvif;
    if (onvif == null) return;
    try {
      await onvif.ptz.stop(camera.onvifProfileToken!);
    } catch (e) {
      debugPrint('PTZ: stop failed: $e');
    }
  }
}
