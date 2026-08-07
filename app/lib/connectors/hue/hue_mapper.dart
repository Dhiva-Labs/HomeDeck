import '../../models/device.dart';

/// Pure JSON → [Device] mapping for the Hue CLIP v2 API.
///
/// Kept free of any HTTP or bridge concerns so the mapping can be tested
/// against fixture JSON without a live bridge — see
/// test/connectors/hue_mapper_test.dart.
///
/// CLIP v2 shape, trimmed to what's used here:
///
/// ```json
/// // GET /clip/v2/resource/light
/// {"id": "<light-rid>", "owner": {"rid": "<device-rid>", "rtype": "device"},
///  "metadata": {"name": "Hue color lamp 1"},
///  "on": {"on": true}, "dimming": {"brightness": 78.0}}
///
/// // GET /clip/v2/resource/device
/// {"id": "<device-rid>", "metadata": {"name": "...", "archetype": "plug"}}
///
/// // GET /clip/v2/resource/room
/// {"id": "<room-rid>", "metadata": {"name": "Living room"},
///  "children": [{"rid": "<device-rid>", "rtype": "device"}]}
///
/// // GET /clip/v2/resource/scene
/// {"id": "<scene-rid>", "metadata": {"name": "Bright"},
///  "group": {"rid": "<room-rid>", "rtype": "room"}}
/// ```

/// Map every light and scene resource from a bridge into [Device]s.
///
/// [lights], [devices], [rooms] and [scenes] are the raw `data` arrays from
/// the corresponding CLIP v2 endpoints.
List<Device> mapHueResources({
  required List<dynamic> lights,
  required List<dynamic> devices,
  required List<dynamic> rooms,
  required List<dynamic> scenes,
}) {
  final roomByDevice = _roomNameByDeviceRid(rooms);
  final archetypeByDevice = _archetypeByDeviceRid(devices);

  final result = <Device>[];
  for (final raw in lights) {
    final device = lightToDevice(
      raw as Map<String, dynamic>,
      roomByDevice: roomByDevice,
      archetypeByDevice: archetypeByDevice,
    );
    if (device != null) result.add(device);
  }
  for (final raw in scenes) {
    final device = sceneToDevice(raw as Map<String, dynamic>, rooms: rooms);
    if (device != null) result.add(device);
  }
  return result;
}

/// One `light` resource → a light or outlet [Device].
///
/// Hue smart plugs surface as an ordinary `light` service with no `dimming`
/// block; the owning device's `metadata.archetype` ("plug") is the only
/// signal that distinguishes them from a bulb, so [archetypeByDevice] must
/// come from the sibling `device` endpoint.
Device? lightToDevice(
  Map<String, dynamic> light, {
  Map<String, String> roomByDevice = const {},
  Map<String, String> archetypeByDevice = const {},
}) {
  final id = light['id'] as String?;
  if (id == null) return null;

  final name = _name(light) ?? 'Hue light';
  final ownerRid = (light['owner'] as Map?)?['rid'] as String?;
  final archetype = ownerRid == null ? null : archetypeByDevice[ownerRid];
  final isPlug = archetype == 'plug';

  final capabilities = <DeviceCapability>{DeviceCapability.toggle};
  final state = <String, dynamic>{'on': (light['on'] as Map?)?['on'] == true};

  final dimming = light['dimming'] as Map<String, dynamic>?;
  if (dimming != null && !isPlug) {
    capabilities.add(DeviceCapability.brightness);
    final brightness = dimming['brightness'];
    if (brightness is num) state['brightness'] = brightness.round();
  }

  return Device(
    id: 'hue:$id',
    connectorId: 'hue',
    name: name,
    kind: isPlug ? DeviceKind.outlet : DeviceKind.light,
    room: ownerRid == null ? null : roomByDevice[ownerRid],
    state: state,
    attrs: {'ownerDeviceId': ?ownerRid},
    capabilities: capabilities,
  );
}

/// One `scene` resource → a momentary [DeviceKind.scene] device.
///
/// Scenes have no persistent on/off state of their own — like Home
/// Assistant's `scene`/`script` domains, activating is the only action, so
/// `state['on']` always reports false (see HaConnector's `deviceFor`).
Device? sceneToDevice(Map<String, dynamic> scene, {List<dynamic> rooms = const []}) {
  final id = scene['id'] as String?;
  if (id == null) return null;

  final groupRid = (scene['group'] as Map?)?['rid'] as String?;
  String? roomName;
  if (groupRid != null) {
    for (final raw in rooms) {
      final room = raw as Map<String, dynamic>;
      if (room['id'] == groupRid) {
        roomName = _name(room);
        break;
      }
    }
  }

  return Device(
    id: 'hue:$id',
    connectorId: 'hue',
    name: _name(scene) ?? 'Hue scene',
    kind: DeviceKind.scene,
    room: roomName,
    state: {'on': false},
    capabilities: {DeviceCapability.toggle},
  );
}

String? _name(Map<String, dynamic> resource) =>
    (resource['metadata'] as Map?)?['name'] as String?;

/// device-rid → room name, built from every room's `children` list.
Map<String, String> _roomNameByDeviceRid(List<dynamic> rooms) {
  final index = <String, String>{};
  for (final raw in rooms) {
    final room = raw as Map<String, dynamic>;
    final roomName = _name(room);
    if (roomName == null) continue;
    for (final child in (room['children'] as List?) ?? const []) {
      final c = child as Map<String, dynamic>;
      if (c['rtype'] != 'device') continue;
      final rid = c['rid'] as String?;
      if (rid != null) index[rid] = roomName;
    }
  }
  return index;
}

/// device-rid → `metadata.archetype`, e.g. "plug", "sultan_bulb".
Map<String, String> _archetypeByDeviceRid(List<dynamic> devices) {
  final index = <String, String>{};
  for (final raw in devices) {
    final device = raw as Map<String, dynamic>;
    final id = device['id'] as String?;
    final archetype = (device['metadata'] as Map?)?['archetype'] as String?;
    if (id != null && archetype != null) index[id] = archetype;
  }
  return index;
}
