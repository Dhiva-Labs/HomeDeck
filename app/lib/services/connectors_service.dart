import 'package:flutter/foundation.dart';

import '../connectors/connector.dart';
import '../models/device.dart';

/// Owns all connectors and routes device actions to the right one.
class ConnectorsService extends ChangeNotifier {
  ConnectorsService(List<Connector> connectors)
      : _byId = {for (final c in connectors) c.id: c};

  final Map<String, Connector> _byId;

  List<Connector> get all => _byId.values.toList();

  T? get<T extends Connector>(String id) => _byId[id] as T?;

  Future<void> startAll() async {
    for (final connector in _byId.values) {
      try {
        await connector.start();
      } catch (e) {
        debugPrint('ConnectorsService: ${connector.id} failed to start: $e');
      }
    }
  }

  Future<void> stopAll() async {
    for (final connector in _byId.values) {
      await connector.stop();
    }
  }

  Future<void> invoke(Device device, DeviceAction action) async {
    final connector = _byId[device.connectorId];
    if (connector == null) {
      debugPrint('ConnectorsService: no connector for ${device.id}');
      return;
    }
    await connector.invoke(device, action);
  }
}
