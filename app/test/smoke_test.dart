import 'package:flutter_test/flutter_test.dart';
import 'package:home_deck/models/device.dart';
import 'package:home_deck/services/device_registry.dart';

void main() {
  group('Device', () {
    test('round-trips through JSON', () {
      final device = Device(
        id: 'netscan:aa:bb:cc:dd:ee:ff',
        connectorId: 'netscan',
        name: 'Desktop PC',
        kind: DeviceKind.computer,
        room: 'Office',
        state: {'on': true},
        attrs: {'ip': '192.168.1.50', 'mac': 'aa:bb:cc:dd:ee:ff'},
        capabilities: {DeviceCapability.wake, DeviceCapability.ping},
      );

      final restored = Device.fromJson(device.toJson());

      expect(restored.id, device.id);
      expect(restored.name, 'Desktop PC');
      expect(restored.kind, DeviceKind.computer);
      expect(restored.room, 'Office');
      expect(restored.isOn, isTrue);
      expect(restored.ip, '192.168.1.50');
      expect(restored.can(DeviceCapability.wake), isTrue);
    });
  });

  group('DeviceRegistry', () {
    test('upsert preserves user overrides', () {
      final registry = DeviceRegistry();
      registry.upsertAll([
        Device(id: 'netscan:1', connectorId: 'netscan', name: 'raw-name'),
      ]);
      registry.rename('netscan:1', 'Living room PC');
      registry.assignRoom('netscan:1', 'Living room');

      // Re-discovery with the raw name must not clobber the user's edits.
      registry.upsertAll([
        Device(id: 'netscan:1', connectorId: 'netscan', name: 'raw-name'),
      ]);

      final device = registry.byId('netscan:1')!;
      expect(device.name, 'Living room PC');
      expect(device.room, 'Living room');
      expect(registry.rooms, contains('Living room'));
    });

    test('markConnectorOffline only affects that connector', () {
      final registry = DeviceRegistry();
      registry.upsertAll([
        Device(id: 'netscan:1', connectorId: 'netscan', name: 'a'),
        Device(id: 'ha:light.x', connectorId: 'ha', name: 'b'),
      ]);

      registry.markConnectorOffline('netscan');

      expect(registry.byId('netscan:1')!.online, isFalse);
      expect(registry.byId('ha:light.x')!.online, isTrue);
    });

    test('hidden devices are excluded from the list', () {
      final registry = DeviceRegistry();
      registry.upsertAll([
        Device(id: 'netscan:1', connectorId: 'netscan', name: 'a'),
      ]);

      registry.hide('netscan:1');

      expect(registry.devices, isEmpty);
      expect(registry.byId('netscan:1'), isNotNull);
    });
  });
}
