import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_deck/connectors/mqtt/discovery_parser.dart';
import 'package:home_deck/models/device.dart';

void main() {
  group('Home Assistant discovery payloads', () {
    test('parses a Zigbee2MQTT light with brightness', () {
      final device = parseHaDiscovery(
        'homeassistant/light/0x00124b/light/config',
        jsonEncode({
          'name': 'Desk lamp',
          'unique_id': '0x00124b_light',
          'state_topic': 'zigbee2mqtt/Desk lamp',
          'command_topic': 'zigbee2mqtt/Desk lamp/set',
          'brightness_command_topic': 'zigbee2mqtt/Desk lamp/set/brightness',
          'brightness_state_topic': 'zigbee2mqtt/Desk lamp/brightness',
          'brightness_scale': 254,
        }),
      )!;

      expect(device.name, 'Desk lamp');
      expect(device.kind, DeviceKind.light);
      expect(device.capabilities, contains(DeviceCapability.toggle));
      expect(device.capabilities, contains(DeviceCapability.brightness));
      expect(device.brightnessScale, 254);
      expect(device.topics, {
        'zigbee2mqtt/Desk lamp',
        'zigbee2mqtt/Desk lamp/brightness',
      });
    });

    test('parses Tasmota abbreviated keys', () {
      // Tasmota abbreviates nearly everything to fit the ESP8266's buffer.
      final device = parseHaDiscovery(
        'homeassistant/switch/ABC123_RL_1/config',
        jsonEncode({
          'name': 'Porch relay',
          'stat_t': 'tele/tasmota_ABC123/STATE',
          'cmd_t': 'cmnd/tasmota_ABC123/POWER',
          'val_tpl': '{{ value_json.POWER }}',
          'pl_on': 'ON',
          'pl_off': 'OFF',
          'uniq_id': 'ABC123_RL_1',
        }),
      )!;

      expect(device.uniqueId, 'ABC123_RL_1');
      expect(device.kind, DeviceKind.switch_);
      expect(device.commandTopic, 'cmnd/tasmota_ABC123/POWER');
      expect(device.valueTemplateKey, 'POWER');
    });

    test('a sensor without a command topic is read-only', () {
      final device = parseHaDiscovery(
        'homeassistant/sensor/esp32_temp/config',
        jsonEncode({
          'name': 'Greenhouse',
          'state_topic': 'esp32/temp',
          'unit_of_measurement': '°C',
          'unique_id': 'esp32_temp',
        }),
      )!;

      expect(device.kind, DeviceKind.sensor);
      expect(device.capabilities, isEmpty);
      expect(device.unit, '°C');
    });

    test('falls back to a topic-derived id when unique_id is absent', () {
      final device = parseHaDiscovery(
        'homeassistant/switch/kitchen_kettle/config',
        jsonEncode({'command_topic': 'cmnd/kettle/POWER'}),
      )!;

      expect(device.uniqueId, contains('kitchen_kettle'));
      expect(device.name, 'kitchen_kettle');
    });

    test('ignores unsupported components and malformed payloads', () {
      expect(
        parseHaDiscovery('homeassistant/device_automation/x/config', '{}'),
        isNull,
      );
      expect(
        parseHaDiscovery('homeassistant/light/x/config', 'not json'),
        isNull,
      );
      expect(
        parseHaDiscovery('homeassistant/light/x/config', '[1,2,3]'),
        isNull,
      );
      expect(parseHaDiscovery('zigbee2mqtt/some/state', '{}'), isNull);
    });

    test('produces a Device carrying the topics needed to control it', () {
      final device = parseHaDiscovery(
        'homeassistant/switch/relay1/config',
        jsonEncode({
          'name': 'Pump',
          'unique_id': 'relay1',
          'state_topic': 'stat/pump/POWER',
          'command_topic': 'cmnd/pump/POWER',
        }),
      )!.toDevice();

      expect(device.id, 'mqtt:relay1');
      expect(device.connectorId, 'mqtt');
      expect(device.attrs['commandTopic'], 'cmnd/pump/POWER');
      // Nothing has reported in yet, so it must not claim to be online.
      expect(device.online, isFalse);
    });
  });

  group('valueTemplateKeyOf', () {
    test('handles dotted and indexed Jinja templates', () {
      expect(valueTemplateKeyOf('{{ value_json.POWER }}'), 'POWER');
      expect(valueTemplateKeyOf("{{ value_json['POWER'] }}"), 'POWER');
      expect(valueTemplateKeyOf('{{ value_json.temperature }}'), 'temperature');
    });

    test('returns null for templates it cannot read', () {
      expect(valueTemplateKeyOf(null), isNull);
      expect(valueTemplateKeyOf('{{ value | round(1) }}'), isNull);
    });
  });

  group('state payloads', () {
    test('reads a plain ON/OFF payload', () {
      expect(parseStatePayload('ON', payloadOn: 'ON')['on'], isTrue);
      expect(parseStatePayload('OFF', payloadOn: 'ON')['on'], isFalse);
      // Casing varies by firmware.
      expect(parseStatePayload('on', payloadOn: 'ON')['on'], isTrue);
    });

    test('extracts a field from a JSON payload via the template key', () {
      final state = parseStatePayload(
        '{"Time":"2026-07-30T18:00:00","POWER":"ON","Uptime":"1T02:00:00"}',
        payloadOn: 'ON',
        valueTemplateKey: 'POWER',
      );

      expect(state['on'], isTrue);
    });

    test('falls back to a "state" field when no template key is given', () {
      final state =
          parseStatePayload('{"state":"ON"}', payloadOn: 'ON');

      expect(state['on'], isTrue);
    });

    test('reads numeric sensor readings as values, not booleans', () {
      final state = parseStatePayload('23.7', payloadOn: 'ON');

      expect(state['value'], 23.7);
    });

    test('respects a non-standard payload_on', () {
      expect(parseStatePayload('1', payloadOn: '1')['on'], isTrue);
      expect(parseStatePayload('0', payloadOn: '1')['on'], isFalse);
    });

    test('returns nothing for JSON it cannot interpret', () {
      expect(
        parseStatePayload('{"Uptime":"1T02:00"}',
            payloadOn: 'ON', valueTemplateKey: 'POWER'),
        isEmpty,
      );
      expect(parseStatePayload('{broken', payloadOn: 'ON'), isEmpty);
    });
  });
}
