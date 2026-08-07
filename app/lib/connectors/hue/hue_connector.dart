import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:multicast_dns/multicast_dns.dart';

import '../../models/device.dart';
import '../connector.dart';
import 'hue_client.dart';
import 'hue_mapper.dart';

/// Bridges a Philips Hue bridge's lights, plugs and scenes into the shared
/// [Device] model, entirely over the LAN via the CLIP v2 API.
///
/// Unlike HaConnector's WebSocket push, CLIP v2's event stream (SSE) is not
/// wired up here — kept simple with a periodic poll instead. Swapping in the
/// event stream later is a drop-in replacement of the polling in [start];
/// see the TODO there.
class HueConnector extends Connector {
  HueConnector(super.registry);

  @override
  String get id => 'hue';

  @override
  String get label => 'Philips Hue';

  static const _pollInterval = Duration(seconds: 10);

  HueClient? _client;
  Timer? _pollTimer;

  String? _bridgeIp;
  String? _applicationKey;

  bool get configured => _bridgeIp != null && _applicationKey != null;

  /// Supply the paired bridge's IP and application key from settings.
  /// Reconnects if either changed. The application key itself comes from
  /// [pairWithBridge]; this connector never mints one on its own.
  Future<void> configure({String? bridgeIp, String? applicationKey}) async {
    final normalized = bridgeIp?.trim();
    if (normalized == _bridgeIp && applicationKey == _applicationKey) return;
    _bridgeIp = (normalized?.isEmpty ?? true) ? null : normalized;
    _applicationKey =
        (applicationKey?.isEmpty ?? true) ? null : applicationKey;
    await stop();
    if (configured) await start();
  }

  @override
  Future<void> start() async {
    if (!configured) {
      setStatus(ConnectorStatus.disabled, 'Not configured');
      return;
    }
    setStatus(ConnectorStatus.starting, 'Connecting to bridge…');
    _client = HueClient(bridgeIp: _bridgeIp!, applicationKey: _applicationKey!);

    await refresh();
    // TODO: replace this poll with the CLIP v2 eventstream
    // (GET /eventstream/clip/v2, text/event-stream) for push updates
    // instead of a fixed interval. Polling is simple and robust enough for
    // M4; the event stream is a follow-up, not a blocker.
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(_pollInterval, (_) => refresh());
  }

  @override
  Future<void> stop() async {
    _pollTimer?.cancel();
    _pollTimer = null;
    _client?.close();
    _client = null;
    registry.markConnectorOffline(id);
    setStatus(ConnectorStatus.disabled);
  }

  @override
  Future<void> refresh() async {
    final client = _client;
    if (client == null) {
      if (configured) return start();
      return;
    }
    try {
      final lights = await client.getResources('light');
      final devices = await client.getResources('device');
      final rooms = await client.getResources('room');
      final scenes = await client.getResources('scene');

      final mapped = mapHueResources(
        lights: lights,
        devices: devices,
        rooms: rooms,
        scenes: scenes,
      );
      registry.upsertAll(mapped);
      setStatus(ConnectorStatus.connected, '${mapped.length} devices');
    } catch (e) {
      setStatus(ConnectorStatus.error, _friendlyError(e));
      registry.markConnectorOffline(id);
    }
  }

  @override
  Future<void> invoke(Device device, DeviceAction action) async {
    final client = _client;
    if (client == null) return;
    // Device ids are "hue:<clip-v2-rid>" — strip the connector prefix.
    final nativeId = device.id.substring(device.id.indexOf(':') + 1);

    if (device.kind == DeviceKind.scene) {
      if (action.name == 'toggle' || action.name == 'turn_on') {
        await client.recallScene(nativeId);
      }
      return; // Scenes are momentary; there is no state to reflect back.
    }

    switch (action.name) {
      case 'turn_on':
        await client.putLight(nativeId, {
          'on': {'on': true},
        });
        registry.updateState(device.id, {'on': true});
      case 'turn_off':
        await client.putLight(nativeId, {
          'on': {'on': false},
        });
        registry.updateState(device.id, {'on': false});
      case 'toggle':
        final turnOn = !device.isOn;
        await client.putLight(nativeId, {
          'on': {'on': turnOn},
        });
        registry.updateState(device.id, {'on': turnOn});
      case 'set_brightness':
        // UI works in 0-100; CLIP v2's dimming.brightness is already 0-100.
        final percent = (action.args['value'] as num).clamp(0, 100).toDouble();
        await client.putLight(nativeId, {
          'on': {'on': percent > 0},
          if (percent > 0) 'dimming': {'brightness': percent},
        });
        registry.updateState(
            device.id, {'brightness': percent.round(), 'on': percent > 0});
    }
  }

  /// Press-the-link-button pairing. POSTs to `https://<ip>/api`; the caller
  /// (settings UI) is expected to prompt "press the link button" and retry
  /// on failure, since the bridge only accepts the request in the ~30s
  /// window after the button is pressed.
  Future<HuePairResult> pairWithBridge(String ip) => HueClient.pairWithBridge(ip);

  String _friendlyError(Object e) {
    final text = '$e'.toLowerCase();
    if (text.contains('401') || text.contains('unauthorized')) {
      return 'Application key rejected — the bridge may have forgotten this '
          'pairing. Pair again.';
    }
    if (text.contains('handshake') || text.contains('certificate')) {
      return 'Could not verify the bridge at $_bridgeIp — is the IP still correct?';
    }
    if (text.contains('refused') || text.contains('socket') ||
        text.contains('timeoutexception')) {
      return 'Could not reach the bridge at $_bridgeIp.';
    }
    return 'Connection failed: $e';
  }

  /// Discover bridges on the LAN via mDNS (`_hue._tcp.local`), falling back
  /// to Hue's cloud discovery endpoint when mDNS finds nothing — some
  /// routers isolate multicast traffic, and Hue bridges have supported this
  /// fallback since the CLIP v1 days specifically for that case.
  static Future<List<String>> discoverBridges({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    final found = <String>{};
    MDnsClient? client;
    try {
      client = MDnsClient();
      await client.start();
      const type = '_hue._tcp.local';
      await for (final ptr in client
          .lookup<PtrResourceRecord>(ResourceRecordQuery.serverPointer(type))
          .timeout(timeout, onTimeout: (sink) => sink.close())) {
        await for (final srv in client
            .lookup<SrvResourceRecord>(
                ResourceRecordQuery.service(ptr.domainName))
            .timeout(timeout, onTimeout: (sink) => sink.close())) {
          await for (final a in client
              .lookup<IPAddressResourceRecord>(
                  ResourceRecordQuery.addressIPv4(srv.target))
              .timeout(timeout, onTimeout: (sink) => sink.close())) {
            found.add(a.address.address);
          }
        }
      }
    } catch (_) {
      // mDNS is best effort; fall through to the cloud fallback below.
    } finally {
      client?.stop();
    }
    if (found.isNotEmpty) return found.toList();

    try {
      final response = await http
          .get(Uri.parse('https://discovery.meethue.com'))
          .timeout(timeout);
      if (response.statusCode == 200) {
        final list = jsonDecode(response.body) as List;
        for (final entry in list) {
          final ip = (entry as Map<String, dynamic>)['internalipaddress'] as String?;
          if (ip != null) found.add(ip);
        }
      }
    } on SocketException {
      // No internet either — caller falls back to manual IP entry.
    } catch (_) {
      // Best effort.
    }
    return found.toList();
  }
}
