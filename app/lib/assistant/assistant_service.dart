import 'dart:async';

import 'package:flutter/foundation.dart';

import '../services/device_registry.dart';
import 'intent.dart';
import 'intent_executor.dart';
import 'nlu/nlu_engine.dart';
import 'voice/voice_interfaces.dart';

enum AssistantPhase {
  /// Mic off entirely (user disabled the assistant, or no permission).
  off,

  /// Wake-word engine running, waiting for the hotword.
  idle,

  /// Wake word heard; streaming STT for the command.
  listening,

  /// Parsing + executing.
  acting,

  /// Speaking the reply / showing the result before returning to idle.
  responding,
}

/// The assistant's brain: one state machine tying wake word -> STT -> NLU ->
/// execution -> TTS.
///
/// Everything voice-specific is behind interfaces so engines can be swapped
/// (and so this class is testable with fakes — see test/assistant/).
class AssistantService extends ChangeNotifier {
  AssistantService({
    required this.registry,
    required this.nlu,
    required this.executor,
    required SpeechRecognizer recognizer,
    required SpeechSynthesizer synthesizer,
  })  : _recognizer = recognizer,
        _synthesizer = synthesizer;

  final DeviceRegistry registry;
  final NluEngine nlu;
  final IntentExecutor executor;
  final SpeechRecognizer _recognizer;
  final SpeechSynthesizer _synthesizer;

  WakeWordEngine? _wakeEngine;
  StreamSubscription<void>? _wakeSub;
  StreamSubscription<SttResult>? _sttSub;

  AssistantPhase _phase = AssistantPhase.off;
  AssistantPhase get phase => _phase;

  /// Live transcript of the current interaction, for the overlay UI.
  String transcript = '';
  String reply = '';
  ExecutionResult? lastResult;

  /// Whether replies are spoken at all (Settings → TTS).
  bool speakReplies = true;

  /// When false (the default), success is silent — the work happens, the UI
  /// shows what happened, and the voice only pipes up for failures and
  /// questions. That is the Google Assistant contract: wake, command, done.
  bool verboseReplies = false;

  /// Pending disambiguation: the previous intent whose target was ambiguous.
  Intent? _pendingIntent;

  bool get muted => _phase == AssistantPhase.off;

  // ---- Lifecycle -------------------------------------------------------------

  /// Start (or restart) idle listening with [engine]. Stops any previous
  /// engine first so exactly one holds the microphone.
  Future<void> enable(
    WakeWordEngine engine, {
    required String keywordAsset,
    double sensitivity = 0.5,
  }) async {
    await disable();
    _wakeEngine = engine;
    await engine.start(keywordAsset: keywordAsset, sensitivity: sensitivity);
    _wakeSub = engine.detections.listen((_) => _onWake());
    _setPhase(AssistantPhase.idle);
  }

  Future<void> disable() async {
    await _sttSub?.cancel();
    _sttSub = null;
    await _wakeSub?.cancel();
    _wakeSub = null;
    await _wakeEngine?.stop();
    await _recognizer.cancel();
    await _synthesizer.stopSpeaking();
    _pendingIntent = null;
    _setPhase(AssistantPhase.off);
  }

  /// Tap-to-talk: same flow as a wake-word hit. Usable even when idle
  /// listening is off (phase == off), e.g. mic permission granted but
  /// hotword disabled.
  Future<void> pushToTalk() => _onWake();

  /// Run a typed command through the same pipeline — the text box in the
  /// assistant sheet, and the integration tests, come through here.
  Future<ExecutionResult> handleText(String utterance) async {
    _setPhase(AssistantPhase.acting);
    transcript = utterance;
    final result = await _handleUtterance(utterance);
    reply = result.spoken;
    lastResult = result;
    _setPhase(_wakeEngine?.running == true
        ? AssistantPhase.idle
        : AssistantPhase.off);
    return result;
  }

  // ---- The interaction loop --------------------------------------------------

  Future<void> _onWake() async {
    if (_phase == AssistantPhase.listening ||
        _phase == AssistantPhase.acting) {
      return; // already mid-interaction
    }
    await _synthesizer.stopSpeaking();
    transcript = '';
    reply = '';
    _setPhase(AssistantPhase.listening);

    final completer = Completer<String>();
    _sttSub = _recognizer.listen().listen(
      (r) {
        transcript = r.text;
        notifyListeners();
        if (r.isFinal && !completer.isCompleted) completer.complete(r.text);
      },
      onError: (Object _) {
        if (!completer.isCompleted) completer.complete('');
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete(transcript);
      },
    );

    final heard = await completer.future;
    await _sttSub?.cancel();
    _sttSub = null;

    if (heard.trim().isEmpty) {
      _pendingIntent = null;
      _setPhase(_backToIdle());
      return;
    }

    _setPhase(AssistantPhase.acting);
    final result = await _handleUtterance(heard);
    reply = result.spoken;
    lastResult = result;
    _setPhase(AssistantPhase.responding);
    if (_shouldSpeak(result)) {
      await _synthesizer.speak(result.spoken);
    }

    if (result.needsDisambiguation) {
      // Listen again immediately for the answer — no wake word needed.
      _setPhase(AssistantPhase.idle);
      await _onWake();
    } else {
      _setPhase(_backToIdle());
    }
  }

  Future<ExecutionResult> _handleUtterance(String utterance) async {
    final context = NluContext(
      deviceNames: registry.devices.map((d) => d.name).toList(),
      roomNames: registry.rooms,
      sceneNames: registry.devices
          .where((d) => d.kind.name == 'scene')
          .map((d) => d.name)
          .toList(),
    );

    var intent = nlu.parse(utterance, context);

    // Disambiguation answer: fold the new target into the pending intent.
    final pending = _pendingIntent;
    _pendingIntent = null;
    if (pending != null && intent.type == IntentType.unknown) {
      intent = Intent(
        type: pending.type,
        target: TargetSpec(phrase: intent.utterance),
        args: pending.args,
        utterance: intent.utterance,
      );
    }

    final result = await executor.execute(intent);
    if (result.needsDisambiguation) _pendingIntent = intent;
    return result;
  }

  /// Queries are spoken (their answer IS the work); questions and failures
  /// are spoken; successful commands stay silent unless [verboseReplies].
  bool _shouldSpeak(ExecutionResult result) {
    if (!speakReplies) return false;
    if (result.needsDisambiguation || !result.ok) return true;
    if (result.isQueryAnswer) return true;
    return verboseReplies;
  }

  AssistantPhase _backToIdle() =>
      _wakeEngine?.running == true ? AssistantPhase.idle : AssistantPhase.off;

  void _setPhase(AssistantPhase phase) {
    _phase = phase;
    notifyListeners();
  }

  @override
  void dispose() {
    disable();
    _wakeEngine?.dispose();
    super.dispose();
  }
}
