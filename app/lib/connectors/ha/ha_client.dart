import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:http/http.dart' as http;
import 'package:web_socket_channel/web_socket_channel.dart';

/// One Home Assistant entity as reported by `get_states` / `state_changed`.
class HaEntity {
  HaEntity({
    required this.entityId,
    required this.state,
    required this.attributes,
  });

  final String entityId;
  final String state;
  final Map<String, dynamic> attributes;

  /// Domain half of the entity id: "light" in "light.kitchen".
  String get domain => entityId.split('.').first;

  String get friendlyName =>
      attributes['friendly_name'] as String? ?? entityId.split('.').last;

  bool get isOn => state == 'on' || state == 'open' || state == 'playing';
  bool get isUnavailable => state == 'unavailable' || state == 'unknown';

  factory HaEntity.fromJson(Map<String, dynamic> json) => HaEntity(
        entityId: json['entity_id'] as String,
        state: json['state'] as String? ?? 'unknown',
        attributes:
            (json['attributes'] as Map?)?.cast<String, dynamic>() ?? {},
      );
}

enum HaConnectionState { disconnected, connecting, authenticating, ready, failed }

/// Home Assistant WebSocket + REST client.
///
/// The WebSocket carries live state; REST is only used for the reachability
/// check during setup, because a bad URL or token should fail fast with a
/// readable message rather than in a reconnect loop.
class HaClient {
  HaClient({required this.baseUrl, required this.token});

  /// e.g. http://homeassistant.local:8123 (no trailing slash)
  final String baseUrl;
  final String token;

  WebSocketChannel? _channel;
  StreamSubscription<dynamic>? _subscription;
  int _messageId = 1;
  Timer? _reconnectTimer;
  bool _closed = false;

  final _states = <String, HaEntity>{};
  final _stateController = StreamController<HaEntity>.broadcast();
  final _connectionController =
      StreamController<HaConnectionState>.broadcast();
  final _pendingResults = <int, Completer<dynamic>>{};

  Map<String, HaEntity> get states => Map.unmodifiable(_states);
  Stream<HaEntity> get onStateChanged => _stateController.stream;
  Stream<HaConnectionState> get onConnectionChanged =>
      _connectionController.stream;

  HaConnectionState _connection = HaConnectionState.disconnected;
  HaConnectionState get connection => _connection;

  String? lastError;

  void _setConnection(HaConnectionState state, [String? error]) {
    _connection = state;
    if (error != null) lastError = error;
    if (!_connectionController.isClosed) _connectionController.add(state);
  }

  Uri get _wsUri {
    final uri = Uri.parse(baseUrl);
    return uri.replace(
      scheme: uri.scheme == 'https' ? 'wss' : 'ws',
      path: '${uri.path.replaceAll(RegExp(r'/$'), '')}/api/websocket',
    );
  }

  /// One-shot REST check used by the settings screen: verifies the URL is a
  /// Home Assistant instance and the token is accepted.
  Future<({bool ok, String message})> testConnection() async {
    try {
      final response = await http.get(
        Uri.parse('$baseUrl/api/'),
        headers: {'Authorization': 'Bearer $token'},
      ).timeout(const Duration(seconds: 8));

      return switch (response.statusCode) {
        200 => (ok: true, message: 'Connected to Home Assistant.'),
        401 => (
            ok: false,
            message: 'Token rejected. Create a new long-lived access token '
                'in your Home Assistant profile.'
          ),
        404 => (
            ok: false,
            message: 'Reached the server, but no Home Assistant API at that '
                'address. Check the port (usually 8123).'
          ),
        _ => (ok: false, message: 'Unexpected response: ${response.statusCode}'),
      };
    } on TimeoutException {
      return (ok: false, message: 'No response — is the address reachable?');
    } catch (e) {
      return (ok: false, message: 'Could not connect: $e');
    }
  }

  /// Connect, authenticate, load all states, and subscribe to changes.
  /// Reconnects on its own until [close] is called.
  Future<void> connect() async {
    _closed = false;
    await _openSocket();
  }

  Future<void> _openSocket() async {
    if (_closed) return;
    _setConnection(HaConnectionState.connecting);
    try {
      final channel = WebSocketChannel.connect(_wsUri);
      await channel.ready.timeout(const Duration(seconds: 10));
      _channel = channel;
      _subscription = channel.stream.listen(
        _onMessage,
        onError: (Object error) => _onDisconnected('$error'),
        onDone: () => _onDisconnected('connection closed'),
        cancelOnError: false,
      );
      _setConnection(HaConnectionState.authenticating);
    } catch (e) {
      _onDisconnected('$e');
    }
  }

  void _onMessage(dynamic raw) {
    final Map<String, dynamic> message;
    try {
      message = jsonDecode(raw as String) as Map<String, dynamic>;
    } catch (e) {
      developer.log('HA: unparseable frame: $e');
      return;
    }

    switch (message['type']) {
      case 'auth_required':
        _send({'type': 'auth', 'access_token': token});
      case 'auth_ok':
        _onAuthenticated();
      case 'auth_invalid':
        _setConnection(HaConnectionState.failed,
            'Token rejected: ${message['message'] ?? 'auth_invalid'}');
        _closed = true; // A bad token will not fix itself by retrying.
        _teardownSocket();
      case 'result':
        final completer = _pendingResults.remove(message['id']);
        if (message['success'] == false) {
          final error = message['error'];
          completer?.completeError(
              'HA error: ${error is Map ? error['message'] : error}');
        } else {
          completer?.complete(message['result']);
        }
      case 'event':
        _onEvent(message['event'] as Map<String, dynamic>?);
    }
  }

  Future<void> _onAuthenticated() async {
    _setConnection(HaConnectionState.ready);
    try {
      final result = await _request({'type': 'get_states'}) as List;
      _states.clear();
      for (final entry in result) {
        final entity = HaEntity.fromJson(entry as Map<String, dynamic>);
        _states[entity.entityId] = entity;
      }
      for (final entity in _states.values) {
        if (!_stateController.isClosed) _stateController.add(entity);
      }
      await _request(
          {'type': 'subscribe_events', 'event_type': 'state_changed'});
    } catch (e) {
      developer.log('HA: bootstrap failed: $e');
      _onDisconnected('$e');
    }
  }

  void _onEvent(Map<String, dynamic>? event) {
    if (event == null || event['event_type'] != 'state_changed') return;
    final data = event['data'] as Map<String, dynamic>?;
    final newState = data?['new_state'];
    if (newState is! Map<String, dynamic>) return; // entity was removed
    final entity = HaEntity.fromJson(newState);
    _states[entity.entityId] = entity;
    if (!_stateController.isClosed) _stateController.add(entity);
  }

  void _onDisconnected(String reason) {
    _teardownSocket();
    if (_closed) return;
    if (_connection != HaConnectionState.failed) {
      _setConnection(HaConnectionState.disconnected, reason);
    }
    // Home Assistant restarts (updates, reboots) are routine; keep retrying.
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(const Duration(seconds: 10), _openSocket);
  }

  void _teardownSocket() {
    _subscription?.cancel();
    _subscription = null;
    _channel?.sink.close();
    _channel = null;
    for (final completer in _pendingResults.values) {
      if (!completer.isCompleted) completer.completeError('disconnected');
    }
    _pendingResults.clear();
  }

  void _send(Map<String, dynamic> message) {
    final channel = _channel;
    if (channel == null) return;
    channel.sink.add(jsonEncode(message));
  }

  Future<dynamic> _request(Map<String, dynamic> message) {
    final id = _messageId++;
    final completer = Completer<dynamic>();
    _pendingResults[id] = completer;
    _send({...message, 'id': id});
    return completer.future.timeout(
      const Duration(seconds: 15),
      onTimeout: () {
        _pendingResults.remove(id);
        throw TimeoutException('Home Assistant did not answer');
      },
    );
  }

  /// Invoke a service, e.g. callService('light', 'turn_on',
  /// entityId: 'light.kitchen', data: {'brightness': 200}).
  Future<void> callService(
    String domain,
    String service, {
    required String entityId,
    Map<String, dynamic> data = const {},
  }) async {
    await _request({
      'type': 'call_service',
      'domain': domain,
      'service': service,
      'target': {'entity_id': entityId},
      if (data.isNotEmpty) 'service_data': data,
    });
  }

  Future<void> close() async {
    _closed = true;
    _reconnectTimer?.cancel();
    _teardownSocket();
    _setConnection(HaConnectionState.disconnected);
    await _stateController.close();
    await _connectionController.close();
  }
}
