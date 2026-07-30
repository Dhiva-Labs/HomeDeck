import 'package:flutter/foundation.dart';

import '../models/device.dart';
import '../services/device_registry.dart';

enum ConnectorStatus { disabled, starting, connected, error }

/// One source of devices (Home Assistant, MQTT, ONVIF, network scan, hub).
///
/// A connector discovers devices, pushes them into the [DeviceRegistry] via
/// [registry.upsertAll], keeps their state fresh while running, and executes
/// [DeviceAction]s for the devices it owns.
abstract class Connector extends ChangeNotifier {
  Connector(this.registry);

  final DeviceRegistry registry;

  /// Stable short id, also the prefix of every owned device id ("ha", "netscan"…).
  String get id;

  String get label;

  ConnectorStatus _status = ConnectorStatus.disabled;
  ConnectorStatus get status => _status;

  String? _statusMessage;
  String? get statusMessage => _statusMessage;

  @protected
  void setStatus(ConnectorStatus status, [String? message]) {
    _status = status;
    _statusMessage = message;
    notifyListeners();
  }

  /// Begin discovery / connect. Must be safe to call repeatedly.
  Future<void> start();

  /// Stop and release resources. Must be safe to call when not started.
  Future<void> stop();

  /// One-shot re-discovery / state refresh.
  Future<void> refresh();

  /// Execute [action] on [device]. Only called for devices with this
  /// connector's [id].
  Future<void> invoke(Device device, DeviceAction action);
}
