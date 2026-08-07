import 'dart:async';

/// Detects the custom wake word from the microphone.
///
/// Implementations: Porcupine (Picovoice) and openWakeWord — the user picks
/// one in settings and can switch at runtime, so [stop] must fully release
/// the microphone before the other engine's [start] is called.
abstract class WakeWordEngine {
  /// Engine id used in settings ("porcupine", "openwakeword").
  String get id;

  String get label;

  /// Fires once per detection while running.
  Stream<void> get detections;

  /// True once [start] succeeded and the mic is being monitored.
  bool get running;

  /// Load the wake-word model and begin listening.
  ///
  /// [keywordAsset] is an engine-specific model file path or asset key (a
  /// .ppn for Porcupine, a .tflite/.onnx for openWakeWord). [sensitivity] is
  /// 0-1, engine-normalized.
  Future<void> start({required String keywordAsset, double sensitivity = 0.5});

  Future<void> stop();

  /// Frees native resources. The engine is unusable afterwards.
  Future<void> dispose();
}

/// One recognized utterance, partial or final.
class SttResult {
  const SttResult(this.text, {required this.isFinal});
  final String text;
  final bool isFinal;
}

/// Speech-to-text for the command that follows the wake word.
abstract class SpeechRecognizer {
  /// Emits partials while the user speaks, then exactly one final result
  /// (which may be empty if nothing was heard) before the stream closes.
  Stream<SttResult> listen({Duration timeout = const Duration(seconds: 8)});

  /// Abort the current session, if any. The active stream closes without a
  /// final result.
  Future<void> cancel();

  Future<bool> get available;
}

/// Text-to-speech for the assistant's replies.
abstract class SpeechSynthesizer {
  /// Speaks [text]; completes when playback finishes or is interrupted.
  Future<void> speak(String text);

  Future<void> stopSpeaking();

  /// 0-1; forwarded to the platform voice.
  set volume(double v);
}
