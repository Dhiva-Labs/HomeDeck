import 'dart:async';
import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';
import 'package:mqtt_client/mqtt_client.dart';
import 'package:mqtt_client/mqtt_server_client.dart';

import '../../models/device.dart';
import '../connector.dart';
import 'discovery_parser.dart';

/// Talks to an MQTT broker and surfaces whatever announces itself there —
/// Tasmota, ESPHome, Zigbee2MQTT, Shelly, or a hand-rolled ESP32 sketch.
///
/// Devices are found through the Home Assistant discovery convention, which
/// is what those firmwares publish by default. No Home Assistant instance is
/// required; only the topic convention is shared.
class MqttConnector extends Connector {
  MqttConnector(super.registry);

  @override
  String get id => 'mqtt';

  @override
  String get label => 'MQTT';

  MqttServerClient? _client;
  StreamSubscription<List<MqttReceivedMessage<MqttMessage>>>? _messageSub;

  String? _host;
  int _port = 1883;
  String? _username;
  String? _password;
  String _discoveryPrefix = 'homeassistant';

  /// Discovered devices keyed by their unique id, and a reverse index from
  /// every subscribed state topic back to the devices that care about it.
  final _devices = <String, MqttDiscoveredDevice>{};
  final _topicIndex = <String, Set<String>>{};

  bool get configured => _host != null && _host!.isNotEmpty;

  int get deviceCount => _devices.length;

  Future<void> configure({
    String? host,
    int port = 1883,
    String? username,
    String? password,
    String discoveryPrefix = 'homeassistant',
  }) async {
    final normalized = host?.trim();
    if (normalized == _host &&
        port == _port &&
        username == _username &&
        password == _password &&
        discoveryPrefix == _discoveryPrefix) {
      return;
    }
    _host = (normalized?.isEmpty ?? true) ? null : normalized;
    _port = port;
    _username = username;
    _password = password;
    _discoveryPrefix = discoveryPrefix;
    await stop();
    if (configured) await start();
  }

  @override
  Future<void> start() async {
    if (!configured) {
      setStatus(ConnectorStatus.disabled, 'Not configured');
      return;
    }
    setStatus(ConnectorStatus.starting, 'Connecting to $_host…');

    final client = MqttServerClient.withPort(
      _host!,
      'homedeck-${DateTime.now().millisecondsSinceEpoch}',
      _port,
    )
      ..logging(on: false)
      ..keepAlivePeriod = 30
      ..autoReconnect = true
      ..resubscribeOnAutoReconnect = true
      ..onDisconnected = _onDisconnected;
    _client = client;

    try {
      await client.connect(_username, _password);
    } catch (e) {
      client.disconnect();
      _client = null;
      setStatus(ConnectorStatus.error, _friendlyError(e));
      return;
    }

    if (client.connectionStatus?.state != MqttConnectionState.connected) {
      setStatus(ConnectorStatus.error,
          _friendlyError(client.connectionStatus?.returnCode));
      return;
    }

    _messageSub = client.updates?.listen(_onMessages);
    // Retained discovery configs arrive immediately on subscribe.
    client.subscribe('$_discoveryPrefix/+/+/config', MqttQos.atMostOnce);
    client.subscribe('$_discoveryPrefix/+/+/+/config', MqttQos.atMostOnce);
    setStatus(ConnectorStatus.connected, 'Connected — waiting for devices');
  }

  @override
  Future<void> stop() async {
    await _messageSub?.cancel();
    _messageSub = null;
    _client?.disconnect();
    _client = null;
    _devices.clear();
    _topicIndex.clear();
    registry.markConnectorOffline(id);
    setStatus(ConnectorStatus.disabled);
  }

  @override
  Future<void> refresh() async {
    if (_client == null && configured) return start();
  }

  void _onDisconnected() {
    registry.markConnectorOffline(id);
    if (status != ConnectorStatus.disabled) {
      setStatus(ConnectorStatus.error, 'Disconnected — retrying');
    }
  }

  void _onMessages(List<MqttReceivedMessage<MqttMessage>> messages) {
    for (final received in messages) {
      final message = received.payload;
      if (message is! MqttPublishMessage) continue;
      final payload = MqttPublishPayload.bytesToStringAsString(
          message.payload.message);
      _onMessage(received.topic, payload);
    }
  }

  /// Route one broker message. Exposed for tests so the discovery → registry
  /// → state flow can be exercised without standing up a broker.
  @visibleForTesting
  void handleMessage(String topic, String payload) {
    if (topic.endsWith('/config')) {
      _onDiscoveryConfig(topic, payload);
      return;
    }
    _onStateMessage(topic, payload);
  }

  void _onMessage(String topic, String payload) =>
      handleMessage(topic, payload);

  void _onDiscoveryConfig(String topic, String payload) {
    // An empty retained payload means the device removed itself.
    if (payload.trim().isEmpty) {
      final removed = _devices.entries
          .where((e) => topic.contains(e.key))
          .map((e) => e.key)
          .toList();
      for (final key in removed) {
        _devices.remove(key);
        registry.updateState('mqtt:$key', {}, online: false);
      }
      return;
    }

    final discovered = parseHaDiscovery(topic, payload);
    if (discovered == null) return;

    _devices[discovered.uniqueId] = discovered;
    registry.upsertAll([discovered.toDevice()]);

    for (final stateTopic in discovered.topics) {
      _topicIndex
          .putIfAbsent(stateTopic, () => <String>{})
          .add(discovered.uniqueId);
      _client?.subscribe(stateTopic, MqttQos.atMostOnce);
    }

    setStatus(ConnectorStatus.connected, '${_devices.length} devices');
  }

  void _onStateMessage(String topic, String payload) {
    final owners = _topicIndex[topic];
    if (owners == null) return;

    for (final uniqueId in owners) {
      final device = _devices[uniqueId];
      if (device == null) continue;

      if (topic == device.brightnessStateTopic) {
        final raw = num.tryParse(payload.trim());
        if (raw != null) {
          registry.updateState(
            'mqtt:$uniqueId',
            {'brightness': (raw * 100 / device.brightnessScale).round()},
            online: true,
          );
        }
        continue;
      }

      final state = parseStatePayload(
        payload,
        payloadOn: device.payloadOn,
        valueTemplateKey: device.valueTemplateKey,
      );
      if (state.isNotEmpty) {
        registry.updateState('mqtt:$uniqueId', state, online: true);
      }
    }
  }

  @override
  Future<void> invoke(Device device, DeviceAction action) async {
    final client = _client;
    if (client == null) return;

    switch (action.name) {
      case 'toggle' || 'turn_on' || 'turn_off':
        final topic = device.attrs['commandTopic'] as String?;
        if (topic == null) return;
        final turnOn = switch (action.name) {
          'turn_on' => true,
          'turn_off' => false,
          _ => !device.isOn,
        };
        _publish(
          topic,
          turnOn
              ? device.attrs['payloadOn'] as String? ?? 'ON'
              : device.attrs['payloadOff'] as String? ?? 'OFF',
        );
        // Optimistic: devices that report state will correct us in a moment.
        registry.updateState(device.id, {'on': turnOn});

      case 'set_brightness':
        final topic = device.attrs['brightnessCommandTopic'] as String?;
        if (topic == null) return;
        final scale = device.attrs['brightnessScale'] as int? ?? 255;
        final percent = (action.args['value'] as num).clamp(0, 100);
        _publish(topic, '${(percent * scale / 100).round()}');
        registry.updateState(device.id, {'brightness': percent.round()});
    }
  }

  void _publish(String topic, String payload) {
    final builder = MqttClientPayloadBuilder()..addString(payload);
    try {
      _client?.publishMessage(topic, MqttQos.atMostOnce, builder.payload!);
    } catch (e) {
      developer.log('MQTT: publish to $topic failed: $e');
    }
  }

  String _friendlyError(Object? error) {
    final text = '$error'.toLowerCase();
    if (text.contains('notauthorized') || text.contains('badusernameorpassword')) {
      return 'Broker rejected the username or password.';
    }
    if (text.contains('refused') || text.contains('socket')) {
      return 'Could not reach the broker at $_host:$_port.';
    }
    return 'Connection failed: $error';
  }
}
