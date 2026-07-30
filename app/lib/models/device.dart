import 'package:flutter/foundation.dart';

/// Broad classification used for icons, default actions and grouping.
enum DeviceKind {
  light,
  outlet,
  switch_,
  sensor,
  climate,
  camera,
  media,
  speaker,
  tv,
  computer,
  phone,
  tablet,
  printer,
  nas,
  router,
  scene,
  unknown,
}

/// What a device can do — drives which controls the UI renders.
enum DeviceCapability {
  toggle,
  brightness,
  colorTemp,
  setValue,
  wake, // Wake-on-LAN
  ping,
  openUrl, // has a web UI
  liveStream,
  snapshot,
  ptz,
}

/// A single controllable/observable thing, normalized across all connectors.
///
/// `id` is stable across restarts: `<connectorId>:<native id>`, e.g.
/// "ha:light.kitchen", "netscan:aa:bb:cc:dd:ee:ff", "onvif:urn:uuid:...".
class Device {
  Device({
    required this.id,
    required this.connectorId,
    required this.name,
    this.kind = DeviceKind.unknown,
    this.room,
    this.online = true,
    Map<String, dynamic>? state,
    Map<String, dynamic>? attrs,
    Set<DeviceCapability>? capabilities,
    DateTime? lastSeen,
  })  : state = state ?? {},
        attrs = attrs ?? {},
        capabilities = capabilities ?? {},
        lastSeen = lastSeen ?? DateTime.now();

  final String id;
  final String connectorId;
  String name;
  DeviceKind kind;
  String? room;
  bool online;

  /// Normalized live state, e.g. {'on': true, 'brightness': 128, 'value': 24.5}.
  Map<String, dynamic> state;

  /// Raw extras: ip, mac, model, manufacturer, streamUrl, entityId…
  Map<String, dynamic> attrs;

  Set<DeviceCapability> capabilities;
  DateTime lastSeen;

  bool get isOn => state['on'] == true;
  String? get ip => attrs['ip'] as String?;
  String? get mac => attrs['mac'] as String?;

  bool can(DeviceCapability c) => capabilities.contains(c);

  Map<String, dynamic> toJson() => {
        'id': id,
        'connectorId': connectorId,
        'name': name,
        'kind': kind.name,
        'room': room,
        'online': online,
        'state': state,
        'attrs': attrs,
        'capabilities': capabilities.map((c) => c.name).toList(),
        'lastSeen': lastSeen.toIso8601String(),
      };

  factory Device.fromJson(Map<String, dynamic> json) => Device(
        id: json['id'] as String,
        connectorId: json['connectorId'] as String,
        name: json['name'] as String? ?? 'Unknown',
        kind: DeviceKind.values.asNameMap()[json['kind']] ?? DeviceKind.unknown,
        room: json['room'] as String?,
        online: json['online'] as bool? ?? false,
        state: (json['state'] as Map?)?.cast<String, dynamic>(),
        attrs: (json['attrs'] as Map?)?.cast<String, dynamic>(),
        capabilities: ((json['capabilities'] as List?) ?? [])
            .map((n) => DeviceCapability.values.asNameMap()[n])
            .whereType<DeviceCapability>()
            .toSet(),
        lastSeen:
            DateTime.tryParse(json['lastSeen'] as String? ?? '') ?? DateTime.now(),
      );

  @override
  bool operator ==(Object other) => other is Device && other.id == id;

  @override
  int get hashCode => id.hashCode;

  @override
  String toString() => 'Device($id, $name, ${kind.name}, online=$online)';
}

/// An action a user can invoke on a device, dispatched to its connector.
@immutable
class DeviceAction {
  const DeviceAction(this.name, [this.args = const {}]);

  final String name; // 'toggle', 'turn_on', 'set_brightness', 'wake', 'ping'…
  final Map<String, dynamic> args;

  @override
  String toString() => 'DeviceAction($name, $args)';
}
