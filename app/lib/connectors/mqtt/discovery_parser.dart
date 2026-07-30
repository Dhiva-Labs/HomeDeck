import 'dart:convert';

import '../../models/device.dart';

/// A device announced on MQTT, normalized from either the Home Assistant
/// discovery convention or the Homie convention.
class MqttDiscoveredDevice {
  MqttDiscoveredDevice({
    required this.uniqueId,
    required this.name,
    required this.kind,
    required this.capabilities,
    this.stateTopic,
    this.commandTopic,
    this.payloadOn = 'ON',
    this.payloadOff = 'OFF',
    this.valueTemplateKey,
    this.unit,
    this.brightnessStateTopic,
    this.brightnessCommandTopic,
    this.brightnessScale = 255,
  });

  final String uniqueId;
  final String name;
  final DeviceKind kind;
  final Set<DeviceCapability> capabilities;

  final String? stateTopic;
  final String? commandTopic;
  final String payloadOn;
  final String payloadOff;

  /// When the state topic carries JSON, the key holding the value —
  /// extracted from a simple `{{ value_json.foo }}` template.
  final String? valueTemplateKey;
  final String? unit;

  final String? brightnessStateTopic;
  final String? brightnessCommandTopic;
  final int brightnessScale;

  /// Every topic this device needs subscribed.
  Set<String> get topics => {
        ?stateTopic,
        ?brightnessStateTopic,
      };

  Device toDevice() => Device(
        id: 'mqtt:$uniqueId',
        connectorId: 'mqtt',
        name: name,
        kind: kind,
        online: false, // until a retained state message arrives
        attrs: {
          'stateTopic': ?stateTopic,
          'commandTopic': ?commandTopic,
          'brightnessCommandTopic': ?brightnessCommandTopic,
          'payloadOn': payloadOn,
          'payloadOff': payloadOff,
          'brightnessScale': brightnessScale,
          'unit': ?unit,
        },
        capabilities: capabilities,
      );
}

/// Parse a Home Assistant MQTT discovery config payload.
///
/// Topic looks like `homeassistant/light/kitchen/config`; the payload is the
/// entity definition. This is what Tasmota, ESPHome, Zigbee2MQTT and
/// Shelly all publish, so supporting it covers most of the ecosystem.
MqttDiscoveredDevice? parseHaDiscovery(String topic, String payload) {
  final parts = topic.split('/');
  if (parts.length < 4 || parts.last != 'config') return null;
  final component = parts[1];

  final Map<String, dynamic> config;
  try {
    final decoded = jsonDecode(payload);
    if (decoded is! Map) return null;
    config = decoded.cast<String, dynamic>();
  } catch (_) {
    return null;
  }

  final kind = switch (component) {
    'light' => DeviceKind.light,
    'switch' => DeviceKind.switch_,
    'fan' => DeviceKind.switch_,
    'binary_sensor' || 'sensor' => DeviceKind.sensor,
    'climate' => DeviceKind.climate,
    'camera' => DeviceKind.camera,
    'cover' => DeviceKind.switch_,
    _ => null,
  };
  if (kind == null) return null;

  // Abbreviated keys are the norm in discovery payloads (Zigbee2MQTT and
  // Tasmota both abbreviate); accept both spellings.
  String? pick(String long, String short) =>
      (config[long] ?? config[short]) as String?;

  final uniqueId = pick('unique_id', 'uniq_id') ??
      '${parts[1]}_${parts[2]}${parts.length > 4 ? '_${parts[3]}' : ''}';

  final device = config['device'] ?? config['dev'];
  final deviceName =
      device is Map ? (device['name'] ?? device['nm']) as String? : null;

  final commandTopic = pick('command_topic', 'cmd_t');
  final stateTopic = pick('state_topic', 'stat_t');

  final capabilities = <DeviceCapability>{};
  if (commandTopic != null) capabilities.add(DeviceCapability.toggle);

  final brightnessCommandTopic = pick('brightness_command_topic', 'bri_cmd_t');
  if (brightnessCommandTopic != null) {
    capabilities.add(DeviceCapability.brightness);
  }

  return MqttDiscoveredDevice(
    uniqueId: uniqueId,
    name: pick('name', 'name') ?? deviceName ?? parts[2],
    kind: kind,
    capabilities: capabilities,
    stateTopic: stateTopic,
    commandTopic: commandTopic,
    payloadOn: pick('payload_on', 'pl_on') ?? 'ON',
    payloadOff: pick('payload_off', 'pl_off') ?? 'OFF',
    valueTemplateKey:
        valueTemplateKeyOf(pick('value_template', 'val_tpl')),
    unit: pick('unit_of_measurement', 'unit_of_meas'),
    brightnessStateTopic: pick('brightness_state_topic', 'bri_stat_t'),
    brightnessCommandTopic: brightnessCommandTopic,
    brightnessScale:
        (config['brightness_scale'] ?? config['bri_scl']) as int? ?? 255,
  );
}

/// Pull the field name out of a simple Jinja value template.
///
/// Full Jinja is out of scope, but `{{ value_json.POWER }}` and
/// `{{ value_json['POWER'] }}` cover what discovery payloads actually use.
String? valueTemplateKeyOf(String? template) {
  if (template == null) return null;
  final dotted =
      RegExp(r'value_json\.([A-Za-z_][A-Za-z0-9_]*)').firstMatch(template);
  if (dotted != null) return dotted.group(1);
  final indexed =
      RegExp(r'''value_json\[.([A-Za-z0-9_ ]+).\]''').firstMatch(template);
  return indexed?.group(1);
}

/// Read a state payload into the normalized `on`/`value` shape.
Map<String, dynamic> parseStatePayload(
  String payload, {
  required String payloadOn,
  String? valueTemplateKey,
}) {
  var text = payload.trim();

  // JSON payloads (Tasmota's tele/.../STATE, Zigbee2MQTT) need the field
  // pulled out before the on/off comparison means anything.
  if (text.startsWith('{')) {
    try {
      final json = jsonDecode(text);
      if (json is Map && valueTemplateKey != null) {
        final extracted = json[valueTemplateKey];
        if (extracted == null) return {};
        text = '$extracted';
      } else if (json is Map && json.containsKey('state')) {
        text = '${json['state']}';
      } else {
        return {};
      }
    } catch (_) {
      return {};
    }
  }

  final numeric = num.tryParse(text);
  return {
    'on': text.toUpperCase() == payloadOn.toUpperCase() ||
        text.toLowerCase() == 'true' ||
        (numeric != null && numeric > 0 && text.length <= 3),
    'value': numeric ?? text,
  };
}
