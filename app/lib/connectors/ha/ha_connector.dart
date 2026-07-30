import 'dart:async';

import 'package:multicast_dns/multicast_dns.dart';

import '../../models/camera.dart';
import '../../models/device.dart';
import '../connector.dart';
import 'ha_client.dart';

/// Bridges Home Assistant entities into the shared [Device] model.
///
/// Only domains HomeDeck can meaningfully show or control are mapped;
/// everything else (automations, updates, diagnostics) is left out so the
/// dashboard stays a control panel rather than an entity dump.
class HaConnector extends Connector {
  HaConnector(super.registry);

  @override
  String get id => 'ha';

  @override
  String get label => 'Home Assistant';

  HaClient? _client;
  StreamSubscription<HaEntity>? _stateSub;
  StreamSubscription<HaConnectionState>? _connectionSub;

  String? _baseUrl;
  String? _token;

  bool get configured => _baseUrl != null && _token != null;

  /// Supply credentials from settings. Reconnects if they changed.
  Future<void> configure({String? baseUrl, String? token}) async {
    final normalized = baseUrl?.trim().replaceAll(RegExp(r'/+$'), '');
    if (normalized == _baseUrl && token == _token) return;
    _baseUrl = (normalized?.isEmpty ?? true) ? null : normalized;
    _token = (token?.isEmpty ?? true) ? null : token;
    await stop();
    if (configured) await start();
  }

  @override
  Future<void> start() async {
    if (!configured) {
      setStatus(ConnectorStatus.disabled, 'Not configured');
      return;
    }
    setStatus(ConnectorStatus.starting, 'Connecting…');

    final client = HaClient(baseUrl: _baseUrl!, token: _token!);
    _client = client;

    _stateSub = client.onStateChanged.listen(_onEntity);
    _connectionSub = client.onConnectionChanged.listen((state) {
      switch (state) {
        case HaConnectionState.ready:
          setStatus(ConnectorStatus.connected,
              '${client.states.length} entities');
        case HaConnectionState.failed:
          setStatus(ConnectorStatus.error, client.lastError);
          registry.markConnectorOffline(id);
        case HaConnectionState.disconnected:
          setStatus(ConnectorStatus.error,
              client.lastError ?? 'Disconnected — retrying');
          registry.markConnectorOffline(id);
        case HaConnectionState.connecting:
        case HaConnectionState.authenticating:
          setStatus(ConnectorStatus.starting, 'Connecting…');
      }
    });

    await client.connect();
  }

  @override
  Future<void> stop() async {
    await _stateSub?.cancel();
    await _connectionSub?.cancel();
    _stateSub = null;
    _connectionSub = null;
    await _client?.close();
    _client = null;
    registry.markConnectorOffline(id);
    setStatus(ConnectorStatus.disabled);
  }

  @override
  Future<void> refresh() async {
    if (_client == null && configured) return start();
  }

  void _onEntity(HaEntity entity) {
    final device = deviceFor(entity, _baseUrl!);
    if (device == null) return;
    registry.upsertAll([device]);
  }

  @override
  Future<void> invoke(Device device, DeviceAction action) async {
    final client = _client;
    final entityId = device.attrs['entityId'] as String?;
    if (client == null || entityId == null) return;
    final domain = entityId.split('.').first;

    switch (action.name) {
      case 'toggle':
        if (domain == 'scene' || domain == 'script') {
          await client.callService(domain, 'turn_on', entityId: entityId);
        } else {
          await client.callService(domain, 'toggle', entityId: entityId);
        }
      case 'turn_on':
        await client.callService(domain, 'turn_on', entityId: entityId);
      case 'turn_off':
        await client.callService(domain, 'turn_off', entityId: entityId);
      case 'set_brightness':
        // UI works in 0-100; Home Assistant lights take 0-255.
        final percent = (action.args['value'] as num).clamp(0, 100);
        await client.callService(
          domain,
          'turn_on',
          entityId: entityId,
          data: {'brightness': (percent * 255 / 100).round()},
        );
      case 'set_temperature':
        await client.callService(
          domain,
          'set_temperature',
          entityId: entityId,
          data: {'temperature': action.args['value']},
        );
    }
  }

  /// Autodetect a Home Assistant instance via mDNS. Returns a base URL.
  static Future<String?> discover({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    MDnsClient? client;
    try {
      client = MDnsClient();
      await client.start();
      const type = '_home-assistant._tcp.local';
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
            return 'http://${a.address.address}:${srv.port}';
          }
        }
      }
    } catch (_) {
      // mDNS is best effort; the user can always type the URL.
    } finally {
      client?.stop();
    }
    return null;
  }
}

/// Map one entity to a [Device], or null when the domain isn't worth showing.
///
/// Pure function so the mapping can be tested without a live instance.
Device? deviceFor(HaEntity entity, String baseUrl) {
  final kind = kindForDomain(entity.domain);
  if (kind == null) return null;

  final capabilities = <DeviceCapability>{};
  final state = <String, dynamic>{};
  final attrs = <String, dynamic>{'entityId': entity.entityId};

  switch (entity.domain) {
    case 'light':
      capabilities.add(DeviceCapability.toggle);
      state['on'] = entity.isOn;
      final brightness = entity.attributes['brightness'];
      if (brightness is num) {
        capabilities.add(DeviceCapability.brightness);
        state['brightness'] = (brightness * 100 / 255).round();
      }
      if (entity.attributes['color_temp_kelvin'] != null) {
        capabilities.add(DeviceCapability.colorTemp);
      }

    case 'switch' || 'input_boolean' || 'fan' || 'automation' || 'siren':
      capabilities.add(DeviceCapability.toggle);
      state['on'] = entity.isOn;

    case 'scene' || 'script':
      capabilities.add(DeviceCapability.toggle);
      state['on'] = false; // momentary: activating is the only action

    case 'cover':
      capabilities.add(DeviceCapability.toggle);
      state['on'] = entity.isOn; // "open" counts as on

    case 'sensor' || 'binary_sensor':
      state['value'] = entity.state;
      attrs['unit'] = entity.attributes['unit_of_measurement'] ?? '';
      if (entity.domain == 'binary_sensor') state['on'] = entity.isOn;

    case 'climate':
      capabilities.add(DeviceCapability.setValue);
      state['on'] = entity.state != 'off';
      state['value'] = entity.attributes['current_temperature'];
      attrs['unit'] = '°';
      attrs['target'] = entity.attributes['temperature'];

    case 'media_player':
      capabilities.add(DeviceCapability.toggle);
      state['on'] = entity.isOn;
      state['value'] = entity.attributes['media_title'];

    case 'camera':
      capabilities
        ..add(DeviceCapability.liveStream)
        ..add(DeviceCapability.snapshot);
      // entity_picture carries a signed token, so the snapshot and MJPEG
      // stream load without an Authorization header — which Image.network
      // and the video player cannot easily send.
      final picture = entity.attributes['entity_picture'] as String?;
      if (picture != null) {
        attrs['snapshotUrl'] = '$baseUrl$picture';
        attrs['streamUrl'] = '$baseUrl'
            '${picture.replaceFirst('/api/camera_proxy/', '/api/camera_proxy_stream/')}';
      }
  }

  return Device(
    id: 'ha:${entity.entityId}',
    connectorId: 'ha',
    name: entity.friendlyName,
    kind: kind,
    online: !entity.isUnavailable,
    state: state,
    attrs: attrs,
    capabilities: capabilities,
  );
}

DeviceKind? kindForDomain(String domain) => switch (domain) {
      'light' => DeviceKind.light,
      'switch' || 'input_boolean' || 'automation' || 'siren' =>
        DeviceKind.switch_,
      'fan' => DeviceKind.switch_,
      'cover' => DeviceKind.switch_,
      'sensor' || 'binary_sensor' => DeviceKind.sensor,
      'climate' || 'water_heater' => DeviceKind.climate,
      'camera' => DeviceKind.camera,
      'media_player' => DeviceKind.media,
      'scene' || 'script' => DeviceKind.scene,
      _ => null,
    };

/// Build a playable [Camera] from a Home Assistant camera device.
Camera? cameraFromDevice(Device device) {
  final streamUrl = device.attrs['streamUrl'] as String?;
  if (streamUrl == null) return null;
  return Camera(
    id: device.id,
    name: device.name,
    streamUrl: streamUrl,
    snapshotUrl: device.attrs['snapshotUrl'] as String?,
    room: device.room,
  );
}
