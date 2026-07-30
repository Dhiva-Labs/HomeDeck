import 'dart:async';

import 'package:flutter/material.dart';

import '../models/camera.dart';

/// Grid thumbnail for one camera.
///
/// Deliberately *not* a video player: N tiles would mean N simultaneous RTSP
/// decodes, which is exactly what kills an old tablet. When the camera
/// exposes a snapshot endpoint we poll a still image instead; otherwise the
/// tile shows a placeholder and live video only opens on tap.
class CameraTile extends StatefulWidget {
  const CameraTile({
    super.key,
    required this.camera,
    this.refreshInterval = const Duration(seconds: 5),
    this.onTap,
  });

  final Camera camera;
  final Duration refreshInterval;
  final VoidCallback? onTap;

  @override
  State<CameraTile> createState() => _CameraTileState();
}

class _CameraTileState extends State<CameraTile> {
  Timer? _timer;
  int _cacheBuster = 0;
  bool _failed = false;

  @override
  void initState() {
    super.initState();
    if (widget.camera.effectiveSnapshotUrl != null) {
      _timer = Timer.periodic(widget.refreshInterval, (_) {
        if (mounted) setState(() => _cacheBuster++);
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshotUrl = widget.camera.effectiveSnapshotUrl;

    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: widget.onTap,
        child: Stack(
          fit: StackFit.expand,
          children: [
            if (snapshotUrl != null && !_failed)
              Image.network(
                '$snapshotUrl${snapshotUrl.contains('?') ? '&' : '?'}_=$_cacheBuster',
                fit: BoxFit.cover,
                gaplessPlayback: true,
                errorBuilder: (context, error, stack) {
                  // Stop hammering an endpoint that isn't serving stills.
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted && !_failed) {
                      setState(() => _failed = true);
                      _timer?.cancel();
                    }
                  });
                  return const _CameraPlaceholder();
                },
              )
            else
              const _CameraPlaceholder(),
            Positioned(
              left: 0,
              right: 0,
              bottom: 0,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                color: Colors.black54,
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.camera.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(color: Colors.white),
                      ),
                    ),
                    const Icon(Icons.play_circle_outline,
                        color: Colors.white70, size: 20),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CameraPlaceholder extends StatelessWidget {
  const _CameraPlaceholder();

  @override
  Widget build(BuildContext context) => ColoredBox(
        color: Colors.black,
        child: Center(
          child: Icon(
            Icons.videocam_outlined,
            size: 40,
            color: Theme.of(context).colorScheme.outline,
          ),
        ),
      );
}
