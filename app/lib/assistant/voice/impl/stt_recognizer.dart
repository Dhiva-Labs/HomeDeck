import 'dart:async';

import 'package:speech_to_text/speech_to_text.dart' as stt;

import '../voice_interfaces.dart';
import 'mic_permission.dart';

/// [SpeechRecognizer] over `speech_to_text`.
///
/// `speech_to_text` wraps a single native recognizer per app, so this class
/// treats [_speech] as shared mutable state: it stops any session already
/// in progress before starting a new one rather than letting the plugin
/// throw its "already listening" error.
class SttSpeechRecognizer implements SpeechRecognizer {
  SttSpeechRecognizer({stt.SpeechToText? speech})
      : _speech = speech ?? stt.SpeechToText();

  final stt.SpeechToText _speech;

  bool _initAttempted = false;
  bool _initOk = false;

  /// Last error or failure reason (plugin error code, `'permission_denied'`,
  /// or an exception string). Not part of [SpeechRecognizer] — exposed for
  /// a diagnostics line in Settings.
  String? lastError;

  @override
  Future<bool> get available async {
    if (_initAttempted) return _initOk;
    _initAttempted = true;

    if (!await ensureMicPermission()) {
      lastError = 'permission_denied';
      return _initOk = false;
    }

    try {
      _initOk = await _speech.initialize(
        onError: (e) => lastError = e.errorMsg,
        onStatus: (_) {},
      );
    } catch (e) {
      lastError = '$e';
      _initOk = false;
    }
    return _initOk;
  }

  @override
  Stream<SttResult> listen({Duration timeout = const Duration(seconds: 8)}) {
    final controller = StreamController<SttResult>();
    unawaited(_run(controller, timeout));
    return controller.stream;
  }

  Future<void> _run(
    StreamController<SttResult> controller,
    Duration timeout,
  ) async {
    if (!await available) {
      // Permission denied or init failed: close without a final result,
      // same as cancel() — lastError carries the reason for the caller.
      await controller.close();
      return;
    }

    if (_speech.isListening) {
      await _speech.stop();
    }

    var done = false;
    void finish(String text, {required bool isFinal}) {
      if (done || controller.isClosed) return;
      controller.add(SttResult(text, isFinal: isFinal));
      if (isFinal) {
        done = true;
        unawaited(controller.close());
      }
    }

    // A permanent error mid-session (permission revoked, engine died) means
    // no final result is ever coming; close rather than leaving the caller
    // waiting on the timeout. Set before starting so an immediate error
    // can't fire before this is wired up.
    _speech.errorListener = (error) {
      lastError = error.errorMsg;
      if (error.permanent && !done && !controller.isClosed) {
        done = true;
        unawaited(controller.close());
      }
    };

    final pauseFor =
        timeout < const Duration(seconds: 3) ? timeout : const Duration(seconds: 3);

    Future<void> start({required bool onDevice}) => _speech.listen(
          onResult: (r) => finish(r.recognizedWords, isFinal: r.finalResult),
          listenOptions: stt.SpeechListenOptions(
            onDevice: onDevice,
            partialResults: true,
            cancelOnError: true,
            listenMode: stt.ListenMode.confirmation,
            listenFor: timeout,
            pauseFor: pauseFor,
          ),
        );

    try {
      // Offline first: "audio never leaves this device" is a product
      // promise, not just a default. Not every locale ships an on-device
      // model, so a rejection here falls back to on/offline auto-select.
      await start(onDevice: true);
    } catch (e) {
      lastError = '$e';
      try {
        await start(onDevice: false);
      } catch (e2) {
        lastError = '$e2';
        if (!done) {
          done = true;
          await controller.close();
        }
      }
    }
  }

  @override
  Future<void> cancel() async {
    if (_speech.isListening) {
      await _speech.cancel();
    }
  }
}
