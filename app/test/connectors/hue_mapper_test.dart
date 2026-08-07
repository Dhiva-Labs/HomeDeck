import 'package:flutter_test/flutter_test.dart';
import 'package:home_deck/connectors/hue/hue_mapper.dart';
import 'package:home_deck/models/device.dart';

/// Exercises the CLIP v2 JSON → Device mapping against fixture payloads —
/// pure functions, no bridge, no network.
void main() {
  group('lightToDevice', () {
    test('a dimmable light in a room maps to a light with brightness', () {
      final light = {
        'id': 'light-1',
        'owner': {'rid': 'device-1', 'rtype': 'device'},
        'metadata': {'name': 'Kitchen ceiling'},
        'on': {'on': true},
        'dimming': {'brightness': 78.0},
      };

      final device = lightToDevice(
        light,
        roomByDevice: {'device-1': 'Kitchen'},
        archetypeByDevice: {'device-1': 'ceiling_round'},
      )!;

      expect(device.id, 'hue:light-1');
      expect(device.connectorId, 'hue');
      expect(device.name, 'Kitchen ceiling');
      expect(device.kind, DeviceKind.light);
      expect(device.room, 'Kitchen');
      expect(device.isOn, isTrue);
      expect(device.state['brightness'], 78);
      expect(device.can(DeviceCapability.toggle), isTrue);
      expect(device.can(DeviceCapability.brightness), isTrue);
    });

    test('a plug-archetype light maps to an outlet without brightness', () {
      final light = {
        'id': 'light-2',
        'owner': {'rid': 'device-2', 'rtype': 'device'},
        'metadata': {'name': 'Lamp plug'},
        'on': {'on': false},
      };

      final device = lightToDevice(
        light,
        roomByDevice: {'device-2': 'Living room'},
        archetypeByDevice: {'device-2': 'plug'},
      )!;

      expect(device.kind, DeviceKind.outlet);
      expect(device.isOn, isFalse);
      expect(device.can(DeviceCapability.toggle), isTrue);
      expect(device.can(DeviceCapability.brightness), isFalse);
      expect(device.state.containsKey('brightness'), isFalse);
    });

    test('a plug that reports dimming still does not get a brightness capability', () {
      // Defensive: some plug firmwares echo a dimming block anyway; the
      // archetype check must win.
      final light = {
        'id': 'light-3',
        'owner': {'rid': 'device-3', 'rtype': 'device'},
        'metadata': {'name': 'Weird plug'},
        'on': {'on': true},
        'dimming': {'brightness': 100.0},
      };

      final device = lightToDevice(
        light,
        archetypeByDevice: {'device-3': 'plug'},
      )!;

      expect(device.kind, DeviceKind.outlet);
      expect(device.can(DeviceCapability.brightness), isFalse);
    });

    test('a light with no owning device or room falls back gracefully', () {
      final light = {
        'id': 'light-4',
        'on': {'on': false},
      };

      final device = lightToDevice(light)!;

      expect(device.name, 'Hue light');
      expect(device.room, isNull);
      expect(device.kind, DeviceKind.light);
    });

    test('a light with no id maps to null', () {
      expect(lightToDevice({'metadata': {}}), isNull);
    });
  });

  group('sceneToDevice', () {
    test('a scene tied to a room picks up the room name', () {
      final scene = {
        'id': 'scene-1',
        'metadata': {'name': 'Movie night'},
        'group': {'rid': 'room-1', 'rtype': 'room'},
      };
      final rooms = [
        {
          'id': 'room-1',
          'metadata': {'name': 'Living room'},
          'children': <dynamic>[],
        },
      ];

      final device = sceneToDevice(scene, rooms: rooms)!;

      expect(device.id, 'hue:scene-1');
      expect(device.kind, DeviceKind.scene);
      expect(device.room, 'Living room');
      // Scenes are momentary — activating is the only action.
      expect(device.isOn, isFalse);
      expect(device.can(DeviceCapability.toggle), isTrue);
    });

    test('a scene with no matching room has a null room', () {
      final scene = {
        'id': 'scene-2',
        'metadata': {'name': 'Orphan scene'},
        'group': {'rid': 'zone-9', 'rtype': 'zone'},
      };

      final device = sceneToDevice(scene, rooms: const [])!;

      expect(device.room, isNull);
    });
  });

  group('mapHueResources', () {
    test('lights and scenes are combined, rooms and archetypes are resolved end to end', () {
      final devices = mapHueResources(
        lights: [
          {
            'id': 'light-1',
            'owner': {'rid': 'device-1', 'rtype': 'device'},
            'metadata': {'name': 'Bulb'},
            'on': {'on': true},
            'dimming': {'brightness': 40.0},
          },
          {
            'id': 'light-2',
            'owner': {'rid': 'device-2', 'rtype': 'device'},
            'metadata': {'name': 'Plug'},
            'on': {'on': true},
          },
        ],
        devices: [
          {
            'id': 'device-1',
            'metadata': {'name': 'Bulb', 'archetype': 'sultan_bulb'},
          },
          {
            'id': 'device-2',
            'metadata': {'name': 'Plug', 'archetype': 'plug'},
          },
        ],
        rooms: [
          {
            'id': 'room-1',
            'metadata': {'name': 'Bedroom'},
            'children': [
              {'rid': 'device-1', 'rtype': 'device'},
              {'rid': 'device-2', 'rtype': 'device'},
            ],
          },
        ],
        scenes: [
          {
            'id': 'scene-1',
            'metadata': {'name': 'Relax'},
            'group': {'rid': 'room-1', 'rtype': 'room'},
          },
        ],
      );

      expect(devices, hasLength(3));

      final bulb = devices.firstWhere((d) => d.id == 'hue:light-1');
      expect(bulb.room, 'Bedroom');
      expect(bulb.kind, DeviceKind.light);
      expect(bulb.can(DeviceCapability.brightness), isTrue);

      final plug = devices.firstWhere((d) => d.id == 'hue:light-2');
      expect(plug.room, 'Bedroom');
      expect(plug.kind, DeviceKind.outlet);
      expect(plug.can(DeviceCapability.brightness), isFalse);

      final scene = devices.firstWhere((d) => d.id == 'hue:scene-1');
      expect(scene.kind, DeviceKind.scene);
      expect(scene.room, 'Bedroom');
    });

    test('an empty bridge maps to an empty device list', () {
      final devices = mapHueResources(lights: const [], devices: const [], rooms: const [], scenes: const []);
      expect(devices, isEmpty);
    });
  });
}
