import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';
import 'package:provider/provider.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../connectors/camera/ptz_controller.dart';
import '../models/camera.dart';
import '../services/settings_store.dart';
import '../widgets/ptz_pad.dart';

/// Fullscreen live view for one camera. This is the only place a real video
/// decode happens — grids use snapshots so old panels stay responsive.
class CameraViewScreen extends StatefulWidget {
  const CameraViewScreen({super.key, required this.camera});

  final Camera camera;

  @override
  State<CameraViewScreen> createState() => _CameraViewScreenState();
}

class _CameraViewScreenState extends State<CameraViewScreen> {
  late final Player _player;
  late final VideoController _videoController;
  late final PtzController _ptz;
  bool _showPtz = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _ptz = PtzController(widget.camera);

    final lowFx = context.read<SettingsStore>().lowFx;
    _player = Player(
      configuration: const PlayerConfiguration(
        // Small buffer: live view should be current, not smooth-but-late.
        bufferSize: 8 * 1024 * 1024,
      ),
    );
    _videoController = VideoController(
      _player,
      configuration: VideoControllerConfiguration(
        // Old GPUs handle a capped surface far better than a native 4K one.
        height: lowFx ? 480 : null,
      ),
    );

    _player.stream.error.listen((error) {
      if (mounted) setState(() => _error = error);
    });

    _open(preferSubStream: lowFx);
    WakelockPlus.enable();
  }

  Future<void> _open({required bool preferSubStream}) async {
    final url = widget.camera.effectiveUrl(preferSubStream: preferSubStream);
    await _player.open(Media(url), play: true);
    // RTSP over TCP survives packet loss far better across camera brands.
    if (widget.camera.useTcp) {
      final platform = _player.platform;
      if (platform is NativePlayer) {
        await platform.setProperty('rtsp-transport', 'tcp');
      }
    }
  }

  @override
  void dispose() {
    _player.dispose();
    if (!context.read<SettingsStore>().keepScreenOn) {
      WakelockPlus.disable();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        title: Text(widget.camera.name),
        actions: [
          if (_ptz.available)
            IconButton(
              icon: Icon(_showPtz ? Icons.gamepad : Icons.gamepad_outlined),
              tooltip: 'PTZ controls',
              onPressed: () => setState(() => _showPtz = !_showPtz),
            ),
        ],
      ),
      body: Stack(
        children: [
          Center(
            child: Video(
              controller: _videoController,
              controls: NoVideoControls,
              fit: BoxFit.contain,
            ),
          ),
          if (_error != null)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.error_outline,
                        color: Colors.white70, size: 40),
                    const SizedBox(height: 12),
                    Text(
                      'Could not play this stream.\n$_error',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white70),
                    ),
                  ],
                ),
              ),
            ),
          if (_showPtz)
            Positioned(
              right: 16,
              bottom: 16,
              child: PtzPad(controller: _ptz),
            ),
        ],
      ),
    );
  }
}
