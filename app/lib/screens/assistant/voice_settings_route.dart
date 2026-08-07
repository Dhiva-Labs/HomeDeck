import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../assistant/assistant_boot.dart';
import '../../assistant/assistant_service.dart';
import '../../assistant/voice/impl/mic_permission.dart';
import '../../services/settings_store.dart';
import 'voice_settings_screen.dart';

/// Binds the pure [VoiceSettingsScreen] to [SettingsStore] persistence and
/// re-applies the assistant configuration whenever something changes.
class VoiceSettingsRoute extends StatefulWidget {
  const VoiceSettingsRoute({super.key});

  @override
  State<VoiceSettingsRoute> createState() => _VoiceSettingsRouteState();
}

class _VoiceSettingsRouteState extends State<VoiceSettingsRoute> {
  MicPermissionStatus _mic = MicPermissionStatus.notRequested;

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsStore>();
    final assistant = context.read<AssistantService>();

    final data = VoiceSettingsData(
      assistantEnabled: settings.assistantEnabled,
      micPermission: _mic,
      wakeEngine: settings.wakeEngine == 'porcupine'
          ? WakeEngineChoice.porcupine
          : WakeEngineChoice.openEngine,
      wakeWord: settings.wakeWord,
      picovoiceAccessKey: settings.porcupineAccessKey ?? '',
      sensitivity: settings.wakeSensitivity,
      ttsEnabled: settings.ttsEnabled,
      ttsVolume: settings.ttsVolume,
    );

    return VoiceSettingsScreen(
      data: data,
      onRequestMicPermission: () async {
        final ok = await ensureMicPermission();
        setState(() =>
            _mic = ok ? MicPermissionStatus.granted : MicPermissionStatus.denied);
      },
      onChanged: (next) {
        settings
          ..assistantEnabled = next.assistantEnabled
          ..wakeEngine = next.wakeEngine == WakeEngineChoice.porcupine
              ? 'porcupine'
              : 'sherpa'
          ..wakeWord = next.wakeWord
          ..porcupineAccessKey = next.picovoiceAccessKey
          ..wakeSensitivity = next.sensitivity
          ..ttsEnabled = next.ttsEnabled
          ..ttsVolume = next.ttsVolume;
        // Restart/stop the wake engine to match. Fire-and-forget: the
        // service reports through its own phase, not this screen.
        applyAssistantSettings(assistant, settings);
      },
    );
  }
}
