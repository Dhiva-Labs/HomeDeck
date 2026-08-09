import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';

import '../voice_interfaces.dart';
import 'mic_permission.dart';

/// [WakeWordEngine] over sherpa-onnx's streaming `KeywordSpotter` — the
/// open-source, no-vendor-account alternative to Porcupine.
///
/// Model files are not bundled by this layer (see `INTEGRATION_NOTES.md`
/// for the expected asset names). If they're missing, [start] fails soft:
/// it reports the problem on [status] and leaves [running] false rather
/// than crashing, since shipping without a bundled model is expected until
/// the app registers `assets/kws/` in `pubspec.yaml`.
class SherpaKwsWakeWordEngine implements WakeWordEngine {
  SherpaKwsWakeWordEngine({AudioRecorder? recorder})
      : _injectedRecorder = recorder;

  static const _sampleRate = 16000;

  static const _encoderAsset = 'assets/kws/encoder.onnx';
  static const _decoderAsset = 'assets/kws/decoder.onnx';
  static const _joinerAsset = 'assets/kws/joiner.onnx';
  static const _tokensAsset = 'assets/kws/tokens.txt';

  static bool _bindingsReady = false;

  final AudioRecorder? _injectedRecorder;

  /// Created on first use: `record` 6.x's `AudioRecorder()` registers itself
  /// over the platform channel at construction, which must not happen just
  /// because the engine object exists (tests, engine not selected).
  AudioRecorder? _lazyRecorder;
  AudioRecorder get _recorder =>
      _injectedRecorder ?? (_lazyRecorder ??= AudioRecorder());
  final StreamController<void> _detections = StreamController<void>.broadcast();
  final StreamController<String> _status = StreamController<String>.broadcast();

  KeywordSpotter? _spotter;
  double? _spotterThreshold;
  OnlineStream? _stream;
  StreamSubscription<Uint8List>? _sub;
  bool _running = false;

  /// Last init/runtime error message, if any. Not part of [WakeWordEngine];
  /// [status] carries the same information as a stream for UI binding.
  String? lastError;

  @override
  String get id => 'sherpa_kws';

  @override
  String get label => 'Open-source (sherpa-onnx)';

  @override
  Stream<void> get detections => _detections.stream;

  /// Broadcast status/error updates ("running", "stopped", "error: ...").
  /// This is how "models not bundled" surfaces — [start] never throws.
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

    if (keywordAsset.trim().isEmpty) {
      lastError = 'empty keywords string';
      _status.add('error: $lastError');
      return;
    }

    if (!await ensureMicPermission()) {
      lastError = 'permission_denied';
      _status.add('error: $lastError');
      return;
    }

    // Sensitivity (0-1, higher = more triggers) maps inversely onto
    // sherpa-onnx's per-keyword posterior threshold (lower = more triggers).
    // Anchored so the default 0.5 sensitivity lands on 0.25 — sherpa's own
    // recommended threshold; the naive 1-sensitivity mapping made the
    // spotter demand near-certainty and it almost never fired.
    final s = sensitivity.clamp(0.0, 1.0);
    final threshold = (0.45 - 0.4 * s).clamp(0.05, 0.45);
    if (!await _ensureSpotter(threshold)) return; // status already set

    final spotter = _spotter!;
    OnlineStream? stream;
    StreamSubscription<Uint8List>? sub;
    try {
      stream = spotter.createStream(keywords: keywordAsset);

      final audio = await _recorder.startStream(const RecordConfig(
        encoder: AudioEncoder.pcm16bits,
        sampleRate: _sampleRate,
        numChannels: 1,
      ));

      final activeStream = stream;
      sub = audio.listen(
        (chunk) => _onAudioChunk(spotter, activeStream, chunk),
        onError: (Object e) {
          lastError = '$e';
          _status.add('error: $e');
        },
      );

      _stream = stream;
      _sub = sub;
      _running = true;
      _status.add('running');
    } catch (e) {
      await sub?.cancel();
      stream?.free();
      _running = false;
      lastError = '$e';
      _status.add('error: $e');
    }
  }

  /// Loads and caches the native spotter. Rebuilds it only if the requested
  /// [threshold] moved enough to matter — model load is the expensive part
  /// of [start], so repeated start/stop with the same sensitivity is cheap.
  Future<bool> _ensureSpotter(double threshold) async {
    if (_spotter != null && (_spotterThreshold! - threshold).abs() < 0.01) {
      return true;
    }

    try {
      if (!_bindingsReady) {
        initBindings();
        _bindingsReady = true;
      }

      final supportDir = await getApplicationSupportDirectory();
      final modelsDir = Directory('${supportDir.path}/kws_models');
      await modelsDir.create(recursive: true);

      final encoder = await _materialize(_encoderAsset, modelsDir);
      final decoder = await _materialize(_decoderAsset, modelsDir);
      final joiner = await _materialize(_joinerAsset, modelsDir);
      final tokens = await _materialize(_tokensAsset, modelsDir);

      _spotter?.free();
      _spotter = KeywordSpotter(KeywordSpotterConfig(
        model: OnlineModelConfig(
          transducer: OnlineTransducerModelConfig(
            encoder: encoder,
            decoder: decoder,
            joiner: joiner,
          ),
          tokens: tokens,
          modelType: 'zipformer2',
        ),
        keywordsThreshold: threshold,
      ));
      _spotterThreshold = threshold;
      return true;
    } catch (e) {
      _spotter = null;
      _spotterThreshold = null;
      lastError = 'KWS models missing or invalid under assets/kws/ '
          '(see INTEGRATION_NOTES.md): $e';
      _status.add('error: $lastError');
      return false;
    }
  }

  /// Copies a bundled asset to a real file the native FFI layer can open by
  /// path (it cannot read Flutter's asset bundle directly). Skips the copy
  /// if a previous run already materialized it.
  Future<String> _materialize(String assetKey, Directory dir) async {
    final outFile = File('${dir.path}/${assetKey.split('/').last}');
    if (await outFile.exists()) return outFile.path;
    final data = await rootBundle.load(assetKey);
    await outFile.writeAsBytes(
      data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
      flush: true,
    );
    return outFile.path;
  }

  /// Feeds one chunk of 16 kHz mono PCM16 audio through the spotter and
  /// emits a detection when a keyword clears its threshold.
  void _onAudioChunk(KeywordSpotter spotter, OnlineStream stream, Uint8List bytes) {
    final samples = Float32List(bytes.length ~/ 2);
    final data = ByteData.sublistView(bytes);
    for (var i = 0; i < samples.length; i++) {
      samples[i] = data.getInt16(i * 2, Endian.little) / 32768.0;
    }

    stream.acceptWaveform(samples: samples, sampleRate: _sampleRate);
    while (spotter.isReady(stream)) {
      spotter.decode(stream);
    }

    final result = spotter.getResult(stream);
    if (result.keyword.isNotEmpty) {
      spotter.reset(stream);
      _detections.add(null);
    }
  }

  @override
  Future<void> stop() async {
    _running = false;
    try {
      await _sub?.cancel();
      _sub = null;
      // This is the actual mic release the mutual-exclusivity contract
      // needs — Porcupine (or another instance of this engine) may start
      // immediately after. Guarded so stop() before any start() doesn't
      // lazily construct a recorder just to stop it.
      final recorder = _injectedRecorder ?? _lazyRecorder;
      if (recorder != null) await recorder.stop();
    } catch (e) {
      lastError = '$e';
      _status.add('error: $e');
    } finally {
      _stream?.free();
      _stream = null;
      _status.add('stopped');
    }
  }

  @override
  Future<void> dispose() async {
    await stop();
    _spotter?.free();
    _spotter = null;
    final recorder = _injectedRecorder ?? _lazyRecorder;
    _lazyRecorder = null;
    if (recorder != null) await recorder.dispose();
    await _detections.close();
    await _status.close();
  }
}
