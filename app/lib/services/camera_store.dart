import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../models/camera.dart';

/// Persistent list of configured cameras, stored alongside the device
/// registry in the app-support directory.
class CameraStore extends ChangeNotifier {
  final List<Camera> _cameras = [];
  File? _file;
  bool _loaded = false;

  List<Camera> get cameras => List.unmodifiable(_cameras);
  List<Camera> get enabled =>
      _cameras.where((camera) => camera.enabled).toList();

  Camera? byId(String id) =>
      _cameras.where((camera) => camera.id == id).firstOrNull;

  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final dir = await getApplicationSupportDirectory();
      _file = File('${dir.path}/cameras.json');
      if (!await _file!.exists()) return;
      final list = jsonDecode(await _file!.readAsString()) as List;
      _cameras
        ..clear()
        ..addAll(list
            .map((e) => Camera.fromJson(e as Map<String, dynamic>)));
      notifyListeners();
    } catch (e) {
      debugPrint('CameraStore: failed to load: $e');
    }
  }

  Future<void> add(Camera camera) async {
    _cameras.add(camera);
    notifyListeners();
    await _save();
  }

  Future<void> update(Camera camera) async {
    final index = _cameras.indexWhere((c) => c.id == camera.id);
    if (index == -1) return;
    _cameras[index] = camera;
    notifyListeners();
    await _save();
  }

  Future<void> remove(String id) async {
    _cameras.removeWhere((camera) => camera.id == id);
    notifyListeners();
    await _save();
  }

  Future<void> _save() async {
    final file = _file;
    if (file == null) return;
    try {
      await file.writeAsString(
          jsonEncode(_cameras.map((c) => c.toJson()).toList()));
    } catch (e) {
      debugPrint('CameraStore: failed to save: $e');
    }
  }
}
