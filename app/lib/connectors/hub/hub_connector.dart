import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../models/camera.dart';
import '../../models/device.dart';
import '../connector.dart';

/// Talks to a HomeDeck Hub.
///
/// The hub scans continuously and transcodes cameras, so when one is
/// configured the panel offloads both: presence data stays fresh even while
/// the screen is off, and weak devices play the hub's MJPEG instead of
/// decoding RTSP themselves.
class HubConnector extends Connector {
  HubConnector(super.registry);

  @override
  String get id => 'hub';

  @override
  String get label => 'HomeDeck Hub';

  String? _baseUrl;
  Timer? _pollTimer;

  bool get configured => _baseUrl != null;
  String? get baseUrl => _baseUrl;

  Future<void> configure({String? baseUrl}) async {
    var normalized = baseUrl?.trim().replaceAll(RegExp(r'/+$'), '');
    if (normalized != null &&
        normalized.isNotEmpty &&
        !normalized.startsWith('http')) {
      normalized = 'http://$normalized';
    }
    if (normalized == _baseUrl) return;
    _baseUrl = (normalized?.isEmpty ?? true) ? null : normalized;
    await stop();
    if (configured) await start();
  }

  @override
  Future<void> start() async {
    if (!configured) {
      setStatus(ConnectorStatus.disabled, 'Not configured');
      return;
    }
    setStatus(ConnectorStatus.starting, 'Contacting hub…');
    await refresh();
    _pollTimer ??=
        Timer.periodic(const Duration(seconds: 30), (_) => refresh());
  }

  @override
  Future<void> stop() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    registry.markConnectorOffline(id);
    setStatus(ConnectorStatus.disabled);
  }

  @override
  Future<void> refresh() async {
    final base = _baseUrl;
    if (base == null) return;
    try {
      final response = await http
          .get(Uri.parse('$base/api/hosts'))
          .timeout(const Duration(seconds: 8));
      if (response.statusCode != 200) {
        setStatus(ConnectorStatus.error, 'Hub returned ${response.statusCode}');
        return;
      }
      final hosts = (jsonDecode(response.body) as List)
          .cast<Map<String, dynamic>>()
          .map(deviceFromHubHost)
          .toList();
      registry.upsertAll(hosts);
      setStatus(ConnectorStatus.connected, '${hosts.length} devices via hub');
    } on TimeoutException {
      setStatus(ConnectorStatus.error, 'Hub did not respond');
      registry.markConnectorOffline(id);
    } catch (e) {
      setStatus(ConnectorStatus.error, 'Could not reach hub: $e');
      registry.markConnectorOffline(id);
    }
  }

  @override
  Future<void> invoke(Device device, DeviceAction action) async {
    final base = _baseUrl;
    if (base == null) return;
    switch (action.name) {
      case 'wake':
        final mac = device.mac;
        if (mac == null) return;
        // The hub is wired to the LAN, so its magic packet reaches segments
        // a Wi-Fi panel's broadcast may not.
        await http.get(Uri.parse('$base/api/wake?mac=$mac'),
            headers: {'Accept': 'application/json'});
      case 'ping':
        await http.get(Uri.parse('$base/api/scan'));
        await refresh();
    }
  }

  /// Ask the hub to restream a camera, so an old panel shows MJPEG rather
  /// than decoding RTSP itself.
  Camera transcodedCamera(Camera camera) => Camera(
        id: camera.id,
        name: camera.name,
        streamUrl: '$_baseUrl/stream/${camera.id}',
        snapshotUrl: '$_baseUrl/snapshot/${camera.id}',
        room: camera.room,
      );

  /// Register a camera with the hub so it can be restreamed.
  Future<bool> registerCamera(Camera camera) async {
    final base = _baseUrl;
    if (base == null) return false;
    try {
      final response = await http
          .post(
            Uri.parse('$base/api/cameras'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({
              'id': camera.id,
              'name': camera.name,
              'streamUrl': camera.effectiveUrl(),
              'room': camera.room ?? '',
            }),
          )
          .timeout(const Duration(seconds: 8));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }
}

/// Map one `/api/hosts` entry to a [Device]. Pure, so it can be tested
/// against recorded hub payloads.
Device deviceFromHubHost(Map<String, dynamic> host) {
  final ports = ((host['ports'] as List?) ?? []).cast<int>();
  final mac = host['mac'] as String?;
  final ip = host['ip'] as String;

  return Device(
    id: mac != null && mac.isNotEmpty ? 'hub:$mac' : 'hub:ip-$ip',
    connectorId: 'hub',
    name: (host['name'] as String?)?.isNotEmpty == true
        ? host['name'] as String
        : 'Device .${ip.split('.').last}',
    kind: _kindFromHub(host['kind'] as String?),
    online: host['online'] as bool? ?? false,
    attrs: {
      'ip': ip,
      'mac': ?mac,
      'ports': ports,
      if (ports.contains(8123)) 'haCandidate': true,
      if (ports.contains(1883)) 'mqttCandidate': true,
      if (ports.contains(554)) 'rtspCandidate': true,
    },
    capabilities: {
      DeviceCapability.ping,
      if (mac != null && mac.isNotEmpty) DeviceCapability.wake,
    },
  );
}

DeviceKind _kindFromHub(String? kind) => switch (kind) {
      'printer' => DeviceKind.printer,
      'camera' => DeviceKind.camera,
      'nas' => DeviceKind.nas,
      'router' => DeviceKind.router,
      'computer' => DeviceKind.computer,
      'homeassistant' || 'mqtt' => DeviceKind.computer,
      _ => DeviceKind.unknown,
    };
