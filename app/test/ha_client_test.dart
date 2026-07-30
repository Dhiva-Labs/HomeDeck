import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_deck/connectors/ha/ha_client.dart';

/// Minimal stand-in for Home Assistant's WebSocket API, enough to exercise
/// the real auth handshake, get_states bootstrap, event subscription and
/// call_service round-trip without a live instance.
class FakeHaServer {
  FakeHaServer({this.expectedToken = 'good-token'});

  final String expectedToken;
  late HttpServer _server;
  WebSocket? _socket;

  /// Service calls the client made, for assertions.
  final calls = <Map<String, dynamic>>[];

  int get port => _server.port;
  String get baseUrl => 'http://127.0.0.1:$port';

  Future<void> start() async {
    _server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((request) async {
      if (!WebSocketTransformer.isUpgradeRequest(request)) {
        request.response.statusCode = 404;
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(request);
      _socket = socket;
      socket.add(jsonEncode({'type': 'auth_required', 'ha_version': '2026.1'}));
      socket.listen((raw) {
        final message = jsonDecode(raw as String) as Map<String, dynamic>;
        _handle(socket, message);
      });
    });
  }

  void _handle(WebSocket socket, Map<String, dynamic> message) {
    switch (message['type']) {
      case 'auth':
        socket.add(jsonEncode(
          message['access_token'] == expectedToken
              ? {'type': 'auth_ok', 'ha_version': '2026.1'}
              : {'type': 'auth_invalid', 'message': 'Invalid access token'},
        ));
      case 'get_states':
        socket.add(jsonEncode({
          'id': message['id'],
          'type': 'result',
          'success': true,
          'result': [
            {
              'entity_id': 'light.kitchen',
              'state': 'off',
              'attributes': {'friendly_name': 'Kitchen', 'brightness': 0},
            },
            {
              'entity_id': 'sensor.temp',
              'state': '24.0',
              'attributes': {'unit_of_measurement': '°C'},
            },
          ],
        }));
      case 'subscribe_events':
      case 'call_service':
        if (message['type'] == 'call_service') calls.add(message);
        socket.add(jsonEncode({
          'id': message['id'],
          'type': 'result',
          'success': true,
          'result': null,
        }));
    }
  }

  /// Push a state_changed event, as HA does when something actually changes.
  void pushStateChange(String entityId, String state,
      [Map<String, dynamic>? attributes]) {
    _socket?.add(jsonEncode({
      'id': 1,
      'type': 'event',
      'event': {
        'event_type': 'state_changed',
        'data': {
          'entity_id': entityId,
          'new_state': {
            'entity_id': entityId,
            'state': state,
            'attributes': attributes ?? {},
          },
        },
      },
    }));
  }

  /// An entity being removed sends new_state: null — must not crash us.
  void pushEntityRemoved(String entityId) {
    _socket?.add(jsonEncode({
      'id': 1,
      'type': 'event',
      'event': {
        'event_type': 'state_changed',
        'data': {'entity_id': entityId, 'new_state': null},
      },
    }));
  }

  Future<void> stop() async {
    await _socket?.close();
    await _server.close(force: true);
  }
}

void main() {
  late FakeHaServer server;

  setUp(() async {
    server = FakeHaServer();
    await server.start();
  });

  tearDown(() async => server.stop());

  /// Poll until [condition] holds. The client's streams are broadcast, so
  /// subscribing after connect() would miss events that already fired.
  Future<void> until(bool Function() condition,
      {Duration timeout = const Duration(seconds: 5)}) async {
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        fail('condition not met within $timeout');
      }
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
  }

  /// Connect and wait for the initial state bootstrap to finish.
  Future<HaClient> connected({String token = 'good-token'}) async {
    final client = HaClient(baseUrl: server.baseUrl, token: token);
    await client.connect();
    await until(() => client.states.length >= 2);
    return client;
  }

  test('authenticates and loads all states', () async {
    final client = await connected();

    expect(client.connection, HaConnectionState.ready);
    expect(client.states.keys, containsAll(['light.kitchen', 'sensor.temp']));
    expect(client.states['sensor.temp']!.state, '24.0');
    await client.close();
  });

  test('a bad token fails permanently instead of retrying', () async {
    final client = HaClient(baseUrl: server.baseUrl, token: 'wrong');
    final failed = client.onConnectionChanged
        .firstWhere((s) => s == HaConnectionState.failed)
        .timeout(const Duration(seconds: 5));
    await client.connect();

    await failed;
    expect(client.lastError, contains('Invalid access token'));
    await client.close();
  });

  test('live state changes reach subscribers', () async {
    final client = await connected();
    final seen = <HaEntity>[];
    client.onStateChanged.listen(seen.add);

    server.pushStateChange('light.kitchen', 'on', {'brightness': 255});
    await until(() => seen.any((e) => e.entityId == 'light.kitchen'));

    final entity = seen.firstWhere((e) => e.entityId == 'light.kitchen');
    expect(entity.isOn, isTrue);
    expect(entity.attributes['brightness'], 255);
    expect(client.states['light.kitchen']!.isOn, isTrue);
    await client.close();
  });

  test('a removed entity does not crash the event handler', () async {
    final client = await connected();

    server.pushEntityRemoved('light.kitchen');
    // Still alive and processing events afterwards.
    server.pushStateChange('sensor.temp', '25.0');
    await until(() => client.states['sensor.temp']!.state == '25.0');

    expect(client.connection, HaConnectionState.ready);
    await client.close();
  });

  test('callService sends the right domain, service and target', () async {
    final client = await connected();

    await client.callService('light', 'turn_on',
        entityId: 'light.kitchen', data: {'brightness': 128});

    expect(server.calls, hasLength(1));
    final call = server.calls.single;
    expect(call['domain'], 'light');
    expect(call['service'], 'turn_on');
    expect(call['target'], {'entity_id': 'light.kitchen'});
    expect(call['service_data'], {'brightness': 128});
    await client.close();
  });

  test('testConnection reports a clear message when the API is absent',
      () async {
    // The fake server 404s any non-WebSocket request, like a wrong port would.
    final client = HaClient(baseUrl: server.baseUrl, token: 'x');
    final result = await client.testConnection();

    expect(result.ok, isFalse);
    expect(result.message, contains('8123'));
  });
}
