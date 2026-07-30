import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/device.dart';

/// Central store of every known device across all connectors.
///
/// Connectors upsert live data; the user's own edits (rename, room
/// assignment, hidden flag) are kept as overrides so a re-discovery never
/// clobbers them. Persisted as JSON in the app-support directory.
class DeviceRegistry extends ChangeNotifier {
  final Map<String, Device> _devices = {};
  final Map<String, _UserOverride> _overrides = {};
  final List<String> _rooms = [];

  File? _file;
  bool _loaded = false;
  bool _saveQueued = false;

  List<Device> get devices {
    final list = _devices.values
        .where((d) => !(_overrides[d.id]?.hidden ?? false))
        .toList();
    list.sort((a, b) {
      if (a.online != b.online) return a.online ? -1 : 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return list;
  }

  List<String> get rooms => List.unmodifiable(_rooms);

  Device? byId(String id) => _devices[id];

  List<Device> byConnector(String connectorId) =>
      devices.where((d) => d.connectorId == connectorId).toList();

  List<Device> byRoom(String? room) =>
      devices.where((d) => d.room == room).toList();

  List<Device> byKind(DeviceKind kind) =>
      devices.where((d) => d.kind == kind).toList();

  // ---- Connector-facing API -------------------------------------------------

  /// Insert or update devices from a connector, preserving user overrides.
  void upsertAll(Iterable<Device> incoming) {
    for (final device in incoming) {
      final override = _overrides[device.id];
      if (override != null) {
        if (override.name != null) device.name = override.name!;
        if (override.room != null) device.room = override.room;
        if (override.kind != null) device.kind = override.kind!;
      }
      _devices[device.id] = device;
    }
    _queueSave();
    notifyListeners();
  }

  /// Update a single device's live state in place.
  void updateState(String id, Map<String, dynamic> state, {bool? online}) {
    final device = _devices[id];
    if (device == null) return;
    device.state = {...device.state, ...state};
    if (online != null) device.online = online;
    device.lastSeen = DateTime.now();
    notifyListeners();
  }

  /// Mark all of one connector's devices offline (connector stopped/lost).
  void markConnectorOffline(String connectorId) {
    var changed = false;
    for (final device in _devices.values) {
      if (device.connectorId == connectorId && device.online) {
        device.online = false;
        changed = true;
      }
    }
    if (changed) notifyListeners();
  }

  // ---- User-facing edits ----------------------------------------------------

  void rename(String id, String name) {
    final device = _devices[id];
    if (device == null) return;
    device.name = name;
    _override(id).name = name;
    _queueSave();
    notifyListeners();
  }

  void assignRoom(String id, String? room) {
    final device = _devices[id];
    if (device == null) return;
    device.room = room;
    _override(id).room = room;
    if (room != null && !_rooms.contains(room)) _rooms.add(room);
    _queueSave();
    notifyListeners();
  }

  void setKind(String id, DeviceKind kind) {
    final device = _devices[id];
    if (device == null) return;
    device.kind = kind;
    _override(id).kind = kind;
    _queueSave();
    notifyListeners();
  }

  void hide(String id) {
    _override(id).hidden = true;
    _queueSave();
    notifyListeners();
  }

  void forget(String id) {
    _devices.remove(id);
    _overrides.remove(id);
    _queueSave();
    notifyListeners();
  }

  void addRoom(String name) {
    if (name.trim().isEmpty || _rooms.contains(name)) return;
    _rooms.add(name);
    _queueSave();
    notifyListeners();
  }

  void removeRoom(String name) {
    _rooms.remove(name);
    for (final device in _devices.values) {
      if (device.room == name) device.room = null;
    }
    for (final o in _overrides.values) {
      if (o.room == name) o.room = null;
    }
    _queueSave();
    notifyListeners();
  }

  _UserOverride _override(String id) =>
      _overrides.putIfAbsent(id, _UserOverride.new);

  // ---- Persistence ----------------------------------------------------------

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File('${dir.path}/registry.json');
      if (!await _file!.exists()) return;
      final json =
          jsonDecode(await _file!.readAsString()) as Map<String, dynamic>;
      for (final entry in (json['devices'] as List? ?? [])) {
        final device = Device.fromJson(entry as Map<String, dynamic>);
        // Cached devices start offline until a connector confirms them.
        device.online = false;
        _devices[device.id] = device;
      }
      for (final entry
          in ((json['overrides'] as Map?) ?? {}).entries) {
        _overrides[entry.key as String] =
            _UserOverride.fromJson(entry.value as Map<String, dynamic>);
      }
      _rooms
        ..clear()
        ..addAll(((json['rooms'] as List?) ?? []).cast<String>());
      notifyListeners();
    } catch (e) {
      debugPrint('DeviceRegistry: failed to load: $e');
    }
  }

  void _queueSave() {
    if (_saveQueued) return;
    _saveQueued = true;
    // Coalesce bursts of updates into one write.
    Future.delayed(const Duration(seconds: 2), () async {
      _saveQueued = false;
      await _save();
    });
  }

  Future<void> _save() async {
    final file = _file;
    if (file == null) return;
    try {
      final json = {
        'devices': _devices.values.map((d) => d.toJson()).toList(),
        'overrides':
            _overrides.map((id, o) => MapEntry(id, o.toJson())),
        'rooms': _rooms,
      };
      await file.writeAsString(jsonEncode(json));
    } catch (e) {
      debugPrint('DeviceRegistry: failed to save: $e');
    }
  }
}

class _UserOverride {
  _UserOverride({this.name, this.room, this.kind, this.hidden = false});

  String? name;
  String? room;
  DeviceKind? kind;
  bool hidden;

  Map<String, dynamic> toJson() => {
        if (name != null) 'name': name,
        if (room != null) 'room': room,
        if (kind != null) 'kind': kind!.name,
        if (hidden) 'hidden': hidden,
      };

  factory _UserOverride.fromJson(Map<String, dynamic> json) => _UserOverride(
        name: json['name'] as String?,
        room: json['room'] as String?,
        kind: DeviceKind.values.asNameMap()[json['kind']],
        hidden: json['hidden'] as bool? ?? false,
      );
}
