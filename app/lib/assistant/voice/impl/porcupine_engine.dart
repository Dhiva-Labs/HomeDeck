import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:porcupine_flutter/porcupine.dart';
import 'package:porcupine_flutter/porcupine_error.dart';
import 'package:porcupine_flutter/porcupine_manager.dart';

import '../voice_interfaces.dart';

/// [WakeWordEngine] over Picovoice Porcupine.
///
/// Bring-your-own-AccessKey per the Settings copy in the product spec — this
/// class takes it as a constructor argument rather than reading it from
/// storage itself, since persistence is [SettingsStore]'s job, not this
/// layer's.
class PorcupineWakeWordEngine implements WakeWordEngine {
  PorcupineWakeWordEngine({required this.accessKey, this.modelPath});

  /// Picovoice Console AccessKey. Required by every Porcupine call.
  final String accessKey;

  /// Optional path to a non-default Porcupine parameter model file. Null
  /// uses the engine's bundled default for the current language.
  final String? modelPath;

  final StreamController<void> _detections = StreamController<void>.broadcast();
  final StreamController<String> _status = StreamController<String>.broadcast();

  PorcupineManager? _manager;
  bool _running = false;

  /// Last init/runtime error message, if any. Not part of [WakeWordEngine];
  /// [status] carries the same information as a stream for UI binding.
  String? lastError;

  @override
  String get id => 'porcupine';

  @override
  String get label => 'Porcupine';

  @override
  Stream<void> get detections => _detections.stream;

  /// Broadcast status/error updates ("running", "stopped", "error: ...").
  /// This is how init failures surface — [start] itself never throws.
  Stream<String> get status => _status.stream;

  @override
  bool get running => _running;

  @override
  Future<void> start({
    required String keywordAsset,
    double sensitivity = 0.5,
  }) async {
    if (_running) return;
    lastError = null;

    PorcupineManager? manager;
    try {
      final builtIn = matchBuiltInKeyword(keywordAsset);
      final sensitivities = [sensitivity.clamp(0.0, 1.0)];

      manager = builtIn != null
          ? await PorcupineManager.fromBuiltInKeywords(
              accessKey,
              [builtIn],
              _onWake,
              modelPath: modelPath,
              sensitivities: sensitivities,
              errorCallback: _onEngineError,
            )
          : await PorcupineManager.fromKeywordPaths(
              accessKey,
              [keywordAsset],
              _onWake,
              modelPath: modelPath,
              sensitivities: sensitivities,
              errorCallback: _onEngineError,
            );

      await manager.start();
      _manager = manager;
      _running = true;
      _status.add('running');
    } catch (e) {
      // Never leave a half-initialized manager holding native resources or
      // the mic; clean up before reporting the failure.
      await manager?.delete();
      _manager = null;
      _running = false;
      lastError = '$e';
      _status.add('error: $e');
    }
  }

  /// Matches [asset] against [BuiltInKeyword] names (case/spacing
  /// insensitive — "hey google", "HEY_GOOGLE" and "Hey Google" all match
  /// [BuiltInKeyword.HEY_GOOGLE]) so callers can pass either a bundled
  /// keyword name or a path to a custom `.ppn` file.
  ///
  /// Public and static so tests can exercise the matching rules without
  /// touching native Porcupine code.
  @visibleForTesting
  static BuiltInKeyword? matchBuiltInKeyword(String asset) {
    final needle = asset.trim().toLowerCase().replaceAll(RegExp(r'[ -]'), '_');
    for (final keyword in BuiltInKeyword.values) {
      if (keyword.name.toLowerCase() == needle) return keyword;
    }
    return null;
  }

  void _onWake(int keywordIndex) => _detections.add(null);

  void _onEngineError(PorcupineException error) {
    lastError = error.message;
    _status.add('error: ${error.message}');
  }

  @override
  Future<void> stop() async {
    final manager = _manager;
    if (manager == null) {
      _running = false;
      return;
    }
    try {
      // PorcupineManager.stop() tears down the underlying VoiceProcessor's
      // audio recording once its last frame listener is removed, which is
      // what actually releases the mic — required before openWakeWord (or
      // another Porcupine instance) can claim it.
      await manager.stop();
    } catch (e) {
      lastError = '$e';
      _status.add('error: $e');
    } finally {
      _running = false;
      _status.add('stopped');
    }
  }

  @override
  Future<void> dispose() async {
    final manager = _manager;
    _manager = null;
    _running = false;
    if (manager != null) {
      try {
        await manager.delete();
      } catch (e) {
        lastError = '$e';
      }
    }
    await _detections.close();
    await _status.close();
  }
}
