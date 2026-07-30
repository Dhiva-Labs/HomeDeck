import 'package:flutter_test/flutter_test.dart';
import 'package:home_deck/connectors/hub/hub_connector.dart';
import 'package:home_deck/models/camera.dart';
import 'package:home_deck/models/device.dart';
import 'package:home_deck/services/device_registry.dart';

void main() {
  group('hub host mapping', () {
    test('maps a host payload to a Device keyed by MAC', () {
      final device = deviceFromHubHost({
        'ip': '192.168.0.50',
        'mac': 'aa:bb:cc:dd:ee:ff',
        'name': 'nas',
        'kind': 'nas',
        'ports': [22, 445, 5000],
        'online': true,
      });

      expect(device.id, 'hub:aa:bb:cc:dd:ee:ff');
      expect(device.connectorId, 'hub');
      expect(device.name, 'nas');
      expect(device.kind, DeviceKind.nas);
      expect(device.online, isTrue);
      expect(device.can(DeviceCapability.wake), isTrue);
    });

    test('falls back to an IP-keyed id when the hub saw no MAC', () {
      final device = deviceFromHubHost({
        'ip': '192.168.0.77',
        'kind': 'unknown',
        'ports': <int>[],
        'online': true,
      });

      expect(device.id, 'hub:ip-192.168.0.77');
      expect(device.name, 'Device .77');
      // Wake-on-LAN is impossible without a MAC.
      expect(device.can(DeviceCapability.wake), isFalse);
    });

    test('flags hosts that look like Home Assistant, MQTT or a camera', () {
      final ha = deviceFromHubHost(
          {'ip': '192.168.0.10', 'ports': [8123], 'online': true});
      final broker = deviceFromHubHost(
          {'ip': '192.168.0.11', 'ports': [1883], 'online': true});
      final cam = deviceFromHubHost(
          {'ip': '192.168.0.12', 'ports': [554], 'kind': 'camera',
           'online': true});

      expect(ha.attrs['haCandidate'], isTrue);
      expect(broker.attrs['mqttCandidate'], isTrue);
      expect(cam.attrs['rtspCandidate'], isTrue);
      expect(cam.kind, DeviceKind.camera);
    });

    test('offline hosts stay listed rather than disappearing', () {
      final device = deviceFromHubHost({
        'ip': '192.168.0.20',
        'mac': 'aa:bb:cc:dd:ee:01',
        'kind': 'computer',
        'ports': <int>[],
        'online': false,
      });

      expect(device.online, isFalse);
      // Still wakeable — that's the point of tracking a sleeping PC.
      expect(device.can(DeviceCapability.wake), isTrue);
    });

    test('a hub payload survives a round trip into the registry', () {
      final registry = DeviceRegistry();
      registry.upsertAll([
        deviceFromHubHost({
          'ip': '192.168.0.50',
          'mac': 'aa:bb:cc:dd:ee:ff',
          'name': 'raw-hostname',
          'kind': 'computer',
          'ports': [22],
          'online': true,
        })
      ]);
      registry.rename('hub:aa:bb:cc:dd:ee:ff', 'Office PC');

      // The hub re-reports every 30s with its own name; the user's must win.
      registry.upsertAll([
        deviceFromHubHost({
          'ip': '192.168.0.50',
          'mac': 'aa:bb:cc:dd:ee:ff',
          'name': 'raw-hostname',
          'kind': 'computer',
          'ports': [22],
          'online': true,
        })
      ]);

      expect(registry.byId('hub:aa:bb:cc:dd:ee:ff')!.name, 'Office PC');
    });
  });

  group('camera transcoding', () {
    test('rewrites a camera to play through the hub', () async {
      final connector = HubConnector(DeviceRegistry());
      await connector.configure(baseUrl: '192.168.0.50:8477');

      final transcoded = connector.transcodedCamera(Camera(
        id: 'cam1',
        name: 'Front door',
        streamUrl: 'rtsp://192.168.0.104:554/stream1',
        username: 'admin',
        password: 'secret',
      ));

      expect(transcoded.streamUrl, 'http://192.168.0.50:8477/stream/cam1');
      expect(transcoded.snapshotUrl, 'http://192.168.0.50:8477/snapshot/cam1');
      // Camera credentials stay on the hub, never on the panel's URL.
      expect(transcoded.effectiveUrl(), isNot(contains('secret')));
    });

    test('a bare host:port gains the http scheme', () async {
      final connector = HubConnector(DeviceRegistry());
      await connector.configure(baseUrl: '192.168.0.50:8477');

      expect(connector.baseUrl, 'http://192.168.0.50:8477');
      expect(connector.configured, isTrue);
    });

    test('trailing slashes are trimmed so URLs never double up', () async {
      final connector = HubConnector(DeviceRegistry());
      await connector.configure(baseUrl: 'http://192.168.0.50:8477//');

      expect(connector.baseUrl, 'http://192.168.0.50:8477');
    });
  });
}
