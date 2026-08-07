import 'dart:async';

import 'package:flutter_tts/flutter_tts.dart';

import '../voice_interfaces.dart';

/// [SpeechSynthesizer] over `flutter_tts`.
///
/// `awaitSpeakCompletion(true)` is what makes [speak]'s future resolve when
/// the audio actually finishes, instead of the moment the platform accepts
/// the request — the caption bar in the wake→listen→confirm flow dismisses
/// itself right after [speak] returns, so this has to be true completion.
class FlutterTtsSynthesizer implements SpeechSynthesizer {
  FlutterTtsSynthesizer({FlutterTts? tts}) : _tts = tts ?? FlutterTts() {
    _tts.setErrorHandler((msg) {
      // The plugin reports synth errors via this handler rather than
      // throwing out of speak(); mirror that into our own completer so a
      // failed utterance still lets the caller's await return instead of
      // hanging until the timeout below.
      _finishCurrent();
    });
    _tts.setCompletionHandler(_finishCurrent);
    _tts.setCancelHandler(_finishCurrent);
  }

  final FlutterTts _tts;
  Completer<void>? _speaking;
  bool _ready = false;

  Future<void> _ensureReady() async {
    if (_ready) return;
    // Best-effort: some platforms (or old OS TTS engines on API 21 devices)
    // don't support awaiting completion at all. If the call fails, speak()
    // just falls back to "completes when the platform accepts the request".
    try {
      await _tts.awaitSpeakCompletion(true);
    } catch (_) {
      // Fall through — _ready still flips so we don't retry every call.
    }
    _ready = true;
  }

  void _finishCurrent() {
    if (_speaking case final s? when !s.isCompleted) {
      s.complete();
    }
  }

  @override
  Future<void> speak(String text) async {
    if (text.isEmpty) return;
    await _ensureReady();

    // A previous utterance's completer must never leak into this call.
    final completer = Completer<void>();
    _speaking = completer;

    try {
      await _tts.speak(text);
    } catch (_) {
      // speak() itself failed synchronously (e.g. engine not ready) — treat
      // it as silence rather than propagating, matching the other voice
      // components' "never throw uncaught" contract.
      if (!completer.isCompleted) completer.complete();
      return;
    }

    // Guard against a platform that silently never calls the completion
    // handler (seen on some OEM TTS engines) so callers can't hang forever.
    await completer.future.timeout(
      const Duration(seconds: 30),
      onTimeout: () {},
    );
  }

  @override
  Future<void> stopSpeaking() async {
    await _tts.stop();
    _finishCurrent();
  }

  @override
  set volume(double v) {
    // setVolume is async on the platform channel but the interface exposes
    // a synchronous setter; fire-and-forget is correct here since the
    // caller has no result to await and TTS volume takes effect on the next
    // speak() regardless.
    unawaited(_tts.setVolume(v.clamp(0.0, 1.0)));
  }
}
