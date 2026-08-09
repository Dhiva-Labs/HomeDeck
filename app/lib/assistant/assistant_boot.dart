import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../services/settings_store.dart';
import 'assistant_service.dart';
import 'voice/impl/background_listening.dart';
import 'voice/impl/keyword_encoder.dart';
import 'voice/impl/mic_permission.dart';
import 'voice/impl/porcupine_engine.dart';
import 'voice/impl/sherpa_kws_engine.dart';
import 'voice/voice_interfaces.dart';

/// Applies the current voice settings to the [AssistantService]: builds the
/// selected wake engine and starts or stops hotword listening.
///
/// Called once at startup and again whenever the user changes a voice
/// setting. Safe to call repeatedly — [AssistantService.enable] tears down
/// the previous engine first.
Future<void> applyAssistantSettings(
  AssistantService assistant,
  SettingsStore settings,
) async {
  assistant.speakReplies = settings.ttsEnabled;

  if (!settings.assistantEnabled) {
    await BackgroundListening.stop();
    await assistant.disable();
    return;
  }
  if (!await ensureMicPermission()) {
    await assistant.disable();
    debugPrint('assistant: mic permission denied, hotword stays off');
    return;
  }

  final WakeWordEngine engine;
  final String keywordAsset;
  if (settings.wakeEngine == 'porcupine') {
    final accessKey = settings.porcupineAccessKey;
    if (accessKey == null || accessKey.isEmpty) {
      await assistant.disable();
      debugPrint('assistant: porcupine selected but no AccessKey set');
      return;
    }
    engine = PorcupineWakeWordEngine(accessKey: accessKey);
    // A custom-trained .ppn beats the typed name; the typed name still works
    // when it matches one of Porcupine's built-in keywords ("jarvis"…).
    keywordAsset = settings.porcupineKeywordPath ?? settings.wakeWord;
  } else {
    engine = SherpaKwsWakeWordEngine();
    // The spotter needs the wake name as the model's BPE tokens, not text.
    final scores = await rootBundle.loadString('assets/kws/bpe_scores.txt');
    final encoded = KeywordEncoder(scores).encode(settings.wakeWord);
    if (encoded == null) {
      await assistant.disable();
      debugPrint(
          'assistant: wake word "${settings.wakeWord}" has no encodable letters');
      return;
    }
    keywordAsset = encoded;
  }

  try {
    await assistant.enable(
      engine,
      keywordAsset: keywordAsset,
      sensitivity: settings.wakeSensitivity,
    );
    // Alexa mode: a microphone foreground service keeps this engine (and
    // its mic stream) alive when the app leaves the screen or the phone
    // locks. No-op off Android.
    await BackgroundListening.start();
  } catch (e) {
    // A broken engine (missing model assets, bad key) must not take the app
    // down — the panel keeps working, tap-to-talk keeps working.
    debugPrint('assistant: wake engine failed to start: $e');
    await assistant.disable();
    await BackgroundListening.stop();
  }
}
