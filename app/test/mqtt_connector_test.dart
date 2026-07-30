import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_deck/connectors/mqtt/mqtt_connector.dart';
import 'package:home_deck/models/device.dart';
import 'package:home_deck/services/device_registry.dart';

/// Exercises the discovery → registry → live-state flow the way a broker
/// would drive it, without needing a broker running.
void main() {
  late DeviceRegistry registry;
  late MqttConnector connector;

  setUp(() {
    registry = DeviceRegistry();
    connector = MqttConnector(registry);
  });

  String config(Map<String, dynamic> payload) => jsonEncode(payload);

  test('a discovery config registers a controllable device', () {
    connector.handleMessage(
      'homeassistant/switch/pump/config',
      config({
        'name': 'Water pump',
        'unique_id': 'pump',
        'state_topic': 'stat/pump/POWER',
        'command_topic': 'cmnd/pump/POWER',
      }),
    );

    final device = registry.byId('mqtt:pump')!;
    expect(device.name, 'Water pump');
    expect(device.kind, DeviceKind.switch_);
    expect(device.can(DeviceCapability.toggle), isTrue);
    // No state has arrived yet, so it must not claim to be online.
    expect(device.online, isFalse);
    expect(connector.deviceCount, 1);
  });

  test('a state message brings the device online with its value', () {
    connector.handleMessage(
      'homeassistant/switch/pump/config',
      config({
        'name': 'Water pump',
        'unique_id': 'pump',
        'state_topic': 'stat/pump/POWER',
        'command_topic': 'cmnd/pump/POWER',
      }),
    );

    connector.handleMessage('stat/pump/POWER', 'ON');

    final device = registry.byId('mqtt:pump')!;
    expect(device.online, isTrue);
    expect(device.isOn, isTrue);
  });

  test('brightness arrives on its own topic and is scaled to percent', () {
    connector.handleMessage(
      'homeassistant/light/lamp/config',
      config({
        'name': 'Lamp',
        'unique_id': 'lamp',
        'state_topic': 'zigbee2mqtt/Lamp',
        'command_topic': 'zigbee2mqtt/Lamp/set',
        'brightness_state_topic': 'zigbee2mqtt/Lamp/brightness',
        'brightness_command_topic': 'zigbee2mqtt/Lamp/set/brightness',
        'brightness_scale': 254,
      }),
    );

    connector.handleMessage('zigbee2mqtt/Lamp/brightness', '127');

    // 127/254 = 50%
    expect(registry.byId('mqtt:lamp')!.state['brightness'], 50);
  });

  test('a Tasmota JSON state payload is read through its value template', () {
    connector.handleMessage(
      'homeassistant/switch/relay/config',
      config({
        'name': 'Relay',
        'uniq_id': 'relay',
        'stat_t': 'tele/tasmota/STATE',
        'cmd_t': 'cmnd/tasmota/POWER',
        'val_tpl': '{{ value_json.POWER }}',
      }),
    );

    connector.handleMessage(
      'tele/tasmota/STATE',
      '{"Time":"2026-07-30T18:00:00","POWER":"ON","Wifi":{"RSSI":72}}',
    );

    expect(registry.byId('mqtt:relay')!.isOn, isTrue);
  });

  test('state on an unknown topic is ignored', () {
    connector.handleMessage('random/topic', 'ON');

    expect(registry.devices, isEmpty);
  });

  test('an empty retained config marks the device offline', () {
    connector.handleMessage(
      'homeassistant/switch/pump/config',
      config({
        'name': 'Pump',
        'unique_id': 'pump',
        'state_topic': 'stat/pump/POWER',
        'command_topic': 'cmnd/pump/POWER',
      }),
    );
    connector.handleMessage('stat/pump/POWER', 'ON');
    expect(registry.byId('mqtt:pump')!.online, isTrue);

    // Devices clear their discovery topic when they leave.
    connector.handleMessage('homeassistant/switch/pump/config', '');

    expect(registry.byId('mqtt:pump')!.online, isFalse);
  });

  test('two devices sharing a state topic both update', () {
    for (final id in ['relay1', 'relay2']) {
      connector.handleMessage(
        'homeassistant/switch/$id/config',
        config({
          'name': id,
          'unique_id': id,
          'state_topic': 'tele/shared/STATE',
          'command_topic': 'cmnd/$id/POWER',
        }),
      );
    }

    connector.handleMessage('tele/shared/STATE', 'ON');

    expect(registry.byId('mqtt:relay1')!.isOn, isTrue);
    expect(registry.byId('mqtt:relay2')!.isOn, isTrue);
  });

  test('user renames survive a device re-announcing itself', () {
    connector.handleMessage(
      'homeassistant/switch/pump/config',
      config({'name': 'tasmota_ABC123', 'unique_id': 'pump',
        'command_topic': 'cmnd/pump/POWER'}),
    );
    registry.rename('mqtt:pump', 'Garden pump');

    // A broker reconnect replays every retained discovery config.
    connector.handleMessage(
      'homeassistant/switch/pump/config',
      config({'name': 'tasmota_ABC123', 'unique_id': 'pump',
        'command_topic': 'cmnd/pump/POWER'}),
    );

    expect(registry.byId('mqtt:pump')!.name, 'Garden pump');
  });
}
