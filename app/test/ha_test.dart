import 'package:flutter_test/flutter_test.dart';
import 'package:home_deck/connectors/ha/ha_client.dart';
import 'package:home_deck/connectors/ha/ha_connector.dart';
import 'package:home_deck/models/device.dart';

HaEntity entity(String id, String state, [Map<String, dynamic>? attrs]) =>
    HaEntity(entityId: id, state: state, attributes: attrs ?? {});

const base = 'http://homeassistant.local:8123';

void main() {
  group('HaEntity', () {
    test('parses a get_states payload', () {
      final parsed = HaEntity.fromJson({
        'entity_id': 'light.kitchen',
        'state': 'on',
        'attributes': {'friendly_name': 'Kitchen', 'brightness': 255},
      });

      expect(parsed.domain, 'light');
      expect(parsed.friendlyName, 'Kitchen');
      expect(parsed.isOn, isTrue);
      expect(parsed.isUnavailable, isFalse);
    });

    test('falls back to the entity id when no friendly name is set', () {
      expect(entity('switch.porch', 'off').friendlyName, 'porch');
    });

    test('treats unavailable and unknown as not-present', () {
      expect(entity('light.x', 'unavailable').isUnavailable, isTrue);
      expect(entity('light.x', 'unknown').isUnavailable, isTrue);
    });
  });

  group('entity to device mapping', () {
    test('maps a dimmable light with brightness scaled to percent', () {
      final device = deviceFor(
        entity('light.kitchen', 'on',
            {'friendly_name': 'Kitchen', 'brightness': 128}),
        base,
      )!;

      expect(device.id, 'ha:light.kitchen');
      expect(device.kind, DeviceKind.light);
      expect(device.isOn, isTrue);
      expect(device.can(DeviceCapability.toggle), isTrue);
      expect(device.can(DeviceCapability.brightness), isTrue);
      // 128/255 ≈ 50%
      expect(device.state['brightness'], 50);
    });

    test('a light without brightness is toggle-only', () {
      final device = deviceFor(entity('light.porch', 'off'), base)!;

      expect(device.can(DeviceCapability.toggle), isTrue);
      expect(device.can(DeviceCapability.brightness), isFalse);
    });

    test('sensors carry their value and unit', () {
      final device = deviceFor(
        entity('sensor.outside_temp', '31.4',
            {'friendly_name': 'Outside', 'unit_of_measurement': '°C'}),
        base,
      )!;

      expect(device.kind, DeviceKind.sensor);
      expect(device.state['value'], '31.4');
      expect(device.attrs['unit'], '°C');
    });

    test('unavailable entities are marked offline', () {
      final device = deviceFor(entity('switch.heater', 'unavailable'), base)!;

      expect(device.online, isFalse);
    });

    test('camera entities build proxy snapshot and stream URLs', () {
      final device = deviceFor(
        entity('camera.front_door', 'idle', {
          'friendly_name': 'Front door',
          'entity_picture': '/api/camera_proxy/camera.front_door?token=abc123',
        }),
        base,
      )!;

      expect(device.kind, DeviceKind.camera);
      expect(device.attrs['snapshotUrl'],
          '$base/api/camera_proxy/camera.front_door?token=abc123');
      // The signed token must survive the switch to the streaming endpoint.
      expect(device.attrs['streamUrl'],
          '$base/api/camera_proxy_stream/camera.front_door?token=abc123');
    });

    test('camera entities become playable Camera objects', () {
      final device = deviceFor(
        entity('camera.front_door', 'idle', {
          'entity_picture': '/api/camera_proxy/camera.front_door?token=abc',
        }),
        base,
      )!;

      final camera = cameraFromDevice(device)!;

      expect(camera.name, 'front_door');
      expect(camera.streamUrl, contains('camera_proxy_stream'));
      expect(camera.snapshotUrl, contains('camera_proxy'));
    });

    test('a camera with no entity_picture yields no playable camera', () {
      final device = deviceFor(entity('camera.broken', 'idle'), base)!;

      expect(cameraFromDevice(device), isNull);
    });

    test('scenes are momentary rather than stateful', () {
      final device = deviceFor(entity('scene.movie_night', 'on'), base)!;

      expect(device.kind, DeviceKind.scene);
      expect(device.can(DeviceCapability.toggle), isTrue);
      expect(device.isOn, isFalse);
    });

    test('climate exposes current temperature and target', () {
      final device = deviceFor(
        entity('climate.bedroom', 'heat',
            {'current_temperature': 22.5, 'temperature': 24.0}),
        base,
      )!;

      expect(device.kind, DeviceKind.climate);
      expect(device.isOn, isTrue);
      expect(device.state['value'], 22.5);
      expect(device.attrs['target'], 24.0);
    });

    test('noise domains are skipped entirely', () {
      for (final id in [
        'update.home_assistant_core',
        'device_tracker.phone',
        'person.dhivakar',
        'sun.sun',
      ]) {
        expect(deviceFor(entity(id, 'on'), base), isNull, reason: id);
      }
    });
  });

  group('kindForDomain', () {
    test('maps the domains the dashboard can render', () {
      expect(kindForDomain('light'), DeviceKind.light);
      expect(kindForDomain('binary_sensor'), DeviceKind.sensor);
      expect(kindForDomain('media_player'), DeviceKind.media);
      expect(kindForDomain('script'), DeviceKind.scene);
      expect(kindForDomain('nonsense'), isNull);
    });
  });
}
