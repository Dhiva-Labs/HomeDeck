import 'package:flutter/services.dart';

import '../../models/device.dart';
import '../connector.dart';

/// Google Home devices, reached through Android's Home APIs
/// (`com.google.android.gms.home`, Play services).
///
/// Those APIs live entirely in native Android code — there is no way to call
/// Play services' Home module from Dart directly. This connector is
/// therefore a clean scaffold: a Dart-side `Connector` talking to a
/// `MethodChannel('homedeck/googlehome')` with three methods (`init`,
/// `listDevices`, `execute`), and *no* Kotlin/Gradle implementation behind
/// it yet, so the app keeps building on every platform in the meantime.
///
/// Until a native handler is registered, every channel call throws
/// [MissingPluginException]; that is treated as "not set up" rather than a
/// crash, and reported through [ConnectorStatus.error] with a message
/// pointing at docs/google-home-setup.md, which has the Kotlin half as a
/// documented next step (permissions flow, commissioning, gradle
/// dependency, where the MethodChannel handler goes).
///
/// See INTEGRATION_NOTES.md in this directory for what main.dart wiring and
/// the Android project need once that native half exists.
class GoogleHomeConnector extends Connector {
  GoogleHomeConnector(super.registry);

  @override
  String get id => 'ghome';

  @override
  String get label => 'Google Home';

  static const _channel = MethodChannel('homedeck/googlehome');

  static const setupMessage =
      'Needs Google Home Developer Console setup — see docs/google-home-setup.md';

  bool _enabled = false;

  bool get configured => _enabled;

  /// Turns the connector on/off from settings. There are no credentials to
  /// hold here — unlike HaConnector/HueConnector this has nothing to
  /// remember beyond "the user turned this on"; everything else is queried
  /// fresh from the platform side each time.
  Future<void> configure({bool enabled = false}) async {
    if (enabled == _enabled) return;
    _enabled = enabled;
    await stop();
    if (_enabled) await start();
  }

  @override
  Future<void> start() async {
    if (!_enabled) {
      setStatus(ConnectorStatus.disabled, 'Not configured');
      return;
    }
    setStatus(ConnectorStatus.starting, 'Checking Google Home availability…');

    final available = await _call<bool>('init');
    if (available != true) {
      // Either the channel has no native handler (MissingPluginException,
      // caught inside _call) or the native side said it isn't ready
      // (permissions not granted, no structures linked, etc).
      setStatus(ConnectorStatus.error, setupMessage);
      return;
    }

    await refresh();
  }

  @override
  Future<void> stop() async {
    registry.markConnectorOffline(id);
    setStatus(ConnectorStatus.disabled);
  }

  @override
  Future<void> refresh() async {
    if (!_enabled) return;
    final raw = await _call<List<Object?>>('listDevices');
    if (raw == null) {
      // Channel unavailable, or the native call failed — either way the
      // honest state is "needs setup", not a silent empty device list.
      setStatus(ConnectorStatus.error, setupMessage);
      return;
    }
    final devices = raw
        .whereType<Map>()
        .map((json) => _deviceFrom(json.cast<String, dynamic>()))
        .whereType<Device>()
        .toList();
    registry.upsertAll(devices);
    setStatus(ConnectorStatus.connected, '${devices.length} devices');
  }

  @override
  Future<void> invoke(Device device, DeviceAction action) async {
    if (!_enabled) return;
    // Device ids are "ghome:<native id>" — strip the connector prefix.
    final nativeId = device.id.substring(device.id.indexOf(':') + 1);
    await _call<void>('execute', {
      'deviceId': nativeId,
      'action': action.name,
      'args': action.args,
    });
  }

  /// Calls the platform channel, treating both "no native implementation"
  /// ([MissingPluginException] — expected today, since the Kotlin side
  /// doesn't exist) and platform-reported failures as graceful unavailability
  /// rather than letting them crash the connector.
  Future<T?> _call<T>(String method, [Map<String, dynamic>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      setStatus(ConnectorStatus.error, e.message ?? setupMessage);
      return null;
    }
  }

  Device? _deviceFrom(Map<String, dynamic> json) {
    final nativeId = json['id'] as String?;
    if (nativeId == null) return null;
    final type = json['type'] as String?;
    return Device(
      id: 'ghome:$nativeId',
      connectorId: id,
      name: json['name'] as String? ?? 'Google Home device',
      kind: _kindFor(type),
      state: (json['state'] as Map?)?.cast<String, dynamic>() ?? {},
      capabilities: _capabilitiesFor(type),
    );
  }

  DeviceKind _kindFor(String? type) => switch (type) {
        'light' => DeviceKind.light,
        'outlet' => DeviceKind.outlet,
        'switch' => DeviceKind.switch_,
        'thermostat' => DeviceKind.climate,
        _ => DeviceKind.unknown,
      };

  Set<DeviceCapability> _capabilitiesFor(String? type) => switch (type) {
        'light' => {DeviceCapability.toggle, DeviceCapability.brightness},
        'outlet' || 'switch' => {DeviceCapability.toggle},
        'thermostat' => {DeviceCapability.setValue},
        _ => {},
      };
}
