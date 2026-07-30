import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../connectors/camera/onvif_service.dart';
import '../connectors/ha/ha_connector.dart';
import '../models/camera.dart';
import '../models/device.dart';
import '../services/camera_store.dart';
import '../services/device_registry.dart';
import '../widgets/camera_tile.dart';
import 'camera_view_screen.dart';

/// Camera wall: snapshot thumbnails, tap for live video.
class CamerasScreen extends StatelessWidget {
  const CamerasScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<CameraStore>();
    // Home Assistant camera entities appear alongside directly-added cameras,
    // so the wall is one list regardless of where a camera came from.
    final haCameras = context
        .watch<DeviceRegistry>()
        .byConnector('ha')
        .where((device) => device.kind == DeviceKind.camera)
        .map(cameraFromDevice)
        .nonNulls;
    final cameras = [...store.enabled, ...haCameras];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Cameras'),
        actions: [
          IconButton(
            icon: const Icon(Icons.radar),
            tooltip: 'Scan for ONVIF cameras',
            onPressed: () => _scanOnvif(context),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _addManually(context),
        icon: const Icon(Icons.add),
        label: const Text('Add camera'),
      ),
      body: cameras.isEmpty
          ? _EmptyCameras(onScan: () => _scanOnvif(context))
          : GridView.builder(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 88),
              gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
                maxCrossAxisExtent: 420,
                childAspectRatio: 16 / 9,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: cameras.length,
              itemBuilder: (context, i) => CameraTile(
                camera: cameras[i],
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => CameraViewScreen(camera: cameras[i]),
                  ),
                ),
              ),
            ),
    );
  }

  Future<void> _scanOnvif(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (_) => const OnvifScanDialog(),
    );
  }

  Future<void> _addManually(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const AddCameraSheet(),
    );
  }
}

class _EmptyCameras extends StatelessWidget {
  const _EmptyCameras({required this.onScan});

  final VoidCallback onScan;

  @override
  Widget build(BuildContext context) {
    final rtspHosts = context
        .watch<DeviceRegistry>()
        .devices
        .where((d) => d.attrs['rtspCandidate'] == true)
        .toList();

    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.videocam_off_outlined,
                size: 64, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text('No cameras yet',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            Text(
              'Scan for ONVIF cameras, or add any RTSP/HTTP stream by hand — '
              'including DVR channels for analog cameras.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Theme.of(context).colorScheme.outline),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onScan,
              icon: const Icon(Icons.radar),
              label: const Text('Scan for cameras'),
            ),
            if (rtspHosts.isNotEmpty) ...[
              const SizedBox(height: 24),
              Text(
                'The network scan saw RTSP on '
                '${rtspHosts.map((d) => d.ip).join(', ')} — '
                'likely cameras.',
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ],
        ),
      ),
    );
  }
}

/// Discovers ONVIF cameras, then asks for credentials to resolve streams.
class OnvifScanDialog extends StatefulWidget {
  const OnvifScanDialog({super.key});

  @override
  State<OnvifScanDialog> createState() => _OnvifScanDialogState();
}

class _OnvifScanDialogState extends State<OnvifScanDialog> {
  List<DiscoveredCamera>? _found;
  String? _error;

  @override
  void initState() {
    super.initState();
    _scan();
  }

  Future<void> _scan() async {
    setState(() {
      _found = null;
      _error = null;
    });
    try {
      final found = await OnvifService.discover();
      if (mounted) setState(() => _found = found);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('ONVIF camera scan'),
      content: SizedBox(
        width: 400,
        child: switch ((_found, _error)) {
          (_, final String error) => Text('Scan failed: $error'),
          (null, _) => const Row(
              children: [
                SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2)),
                SizedBox(width: 16),
                Text('Looking for cameras…'),
              ],
            ),
          (final List<DiscoveredCamera> found, _) when found.isEmpty =>
            const Text(
              'No ONVIF cameras answered. Some cameras have ONVIF disabled '
              'by default — enable it in the camera\'s own web UI, or add '
              'the RTSP URL by hand.',
            ),
          (final List<DiscoveredCamera> found, _) => ListView(
              shrinkWrap: true,
              children: [
                for (final camera in found)
                  ListTile(
                    leading: const Icon(Icons.videocam_outlined),
                    title: Text(camera.name),
                    subtitle: Text(camera.host),
                    onTap: () {
                      Navigator.pop(context);
                      showModalBottomSheet<void>(
                        context: context,
                        isScrollControlled: true,
                        showDragHandle: true,
                        builder: (_) => AddCameraSheet(discovered: camera),
                      );
                    },
                  ),
              ],
            ),
        },
      ),
      actions: [
        TextButton(onPressed: _scan, child: const Text('Rescan')),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

/// Add a camera: either finish an ONVIF discovery (credentials → profiles)
/// or type an RTSP/HTTP URL directly.
class AddCameraSheet extends StatefulWidget {
  const AddCameraSheet({super.key, this.discovered});

  final DiscoveredCamera? discovered;

  @override
  State<AddCameraSheet> createState() => _AddCameraSheetState();
}

class _AddCameraSheetState extends State<AddCameraSheet> {
  final _name = TextEditingController();
  final _url = TextEditingController();
  final _snapshot = TextEditingController();
  final _user = TextEditingController();
  final _pass = TextEditingController();

  bool _resolving = false;
  String? _status;
  List<OnvifStream>? _streams;

  @override
  void initState() {
    super.initState();
    if (widget.discovered != null) {
      _name.text = widget.discovered!.name;
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _url.dispose();
    _snapshot.dispose();
    _user.dispose();
    _pass.dispose();
    super.dispose();
  }

  Future<void> _resolveOnvif() async {
    final host = widget.discovered?.host;
    if (host == null) return;
    setState(() {
      _resolving = true;
      _status = null;
    });
    try {
      final streams = await OnvifService.fetchStreams(
        host: host,
        username: _user.text,
        password: _pass.text,
      );
      setState(() {
        _streams = streams;
        _status = streams.isEmpty
            ? 'Connected, but the camera exposed no streams.'
            : '${streams.length} stream(s) found.';
        final main = OnvifService.pickMainStream(streams);
        if (main != null) _url.text = main.rtspUrl;
      });
    } catch (e) {
      setState(() => _status = 'Could not connect: $e');
    } finally {
      if (mounted) setState(() => _resolving = false);
    }
  }

  Future<void> _save() async {
    final store = context.read<CameraStore>();
    final streams = _streams;
    final sub = streams == null ? null : OnvifService.pickSubStream(streams);
    final main = streams == null ? null : OnvifService.pickMainStream(streams);

    final camera = Camera(
      name: _name.text.trim().isEmpty ? 'Camera' : _name.text.trim(),
      streamUrl: _url.text.trim(),
      subStreamUrl:
          sub != null && sub.rtspUrl != main?.rtspUrl ? sub.rtspUrl : null,
      snapshotUrl:
          _snapshot.text.trim().isEmpty ? null : _snapshot.text.trim(),
      username: _user.text,
      password: _pass.text,
      onvifHost: widget.discovered?.host,
      onvifProfileToken: main?.profileToken,
    );
    await store.add(camera);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final isOnvif = widget.discovered != null;

    return Padding(
      padding: EdgeInsets.only(
        left: 16,
        right: 16,
        bottom: MediaQuery.of(context).viewInsets.bottom + 16,
      ),
      child: ListView(
        shrinkWrap: true,
        children: [
          Text(
            isOnvif ? 'Add ${widget.discovered!.name}' : 'Add camera',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'e.g. Front door',
            ),
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _user,
                  decoration: const InputDecoration(labelText: 'Username'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: TextField(
                  controller: _pass,
                  obscureText: true,
                  decoration: const InputDecoration(labelText: 'Password'),
                ),
              ),
            ],
          ),
          if (isOnvif) ...[
            const SizedBox(height: 12),
            FilledButton.tonalIcon(
              onPressed: _resolving ? null : _resolveOnvif,
              icon: _resolving
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.link),
              label: const Text('Fetch streams from camera'),
            ),
          ],
          if (_status != null) ...[
            const SizedBox(height: 8),
            Text(_status!, style: Theme.of(context).textTheme.bodySmall),
          ],
          const SizedBox(height: 12),
          TextField(
            controller: _url,
            decoration: const InputDecoration(
              labelText: 'Stream URL',
              hintText: 'rtsp://192.168.0.104:554/stream1',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _snapshot,
            decoration: const InputDecoration(
              labelText: 'Snapshot URL (optional)',
              hintText: 'http://192.168.0.104/snapshot.jpg',
              helperText: 'Used for grid thumbnails — much lighter than video',
            ),
          ),
          const SizedBox(height: 20),
          FilledButton(
            onPressed: _url.text.trim().isEmpty ? null : _save,
            child: const Padding(
              padding: EdgeInsets.all(12),
              child: Text('Add camera'),
            ),
          ),
        ],
      ),
    );
  }
}
