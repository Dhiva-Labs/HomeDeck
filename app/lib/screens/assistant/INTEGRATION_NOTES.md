# Assistant UI — integration notes

Everything under `lib/screens/assistant/` and `lib/widgets/assistant/` was
built to a strict file boundary: nothing outside those two directories (plus
`test/screens/assistant/`) was touched. This file is the checklist for
wiring the UI into the rest of the app — none of it has been done yet.

## 1. Provide `AssistantService` app-wide

`AssistantFab` and `AssistantSheet` both call `context.watch<AssistantService>()`
/ `context.read<AssistantService>()`. They assume an `AssistantService`
instance is already available via `provider` above wherever they're mounted
— the same way `DeviceRegistry`, `ConnectorsService` and `SettingsStore`
already are (per `main.dart`'s existing `MultiProvider`).

Add a `ChangeNotifierProvider<AssistantService>` (or
`ChangeNotifierProvider.value` if it's constructed once at startup) to that
`MultiProvider` in `main.dart`, alongside the existing providers. It needs:

```dart
AssistantService(
  registry: <existing DeviceRegistry instance>,
  nlu: RulesNlu(),                         // lib/assistant/nlu/rules_nlu.dart
  executor: IntentExecutor(connectorsService, DeviceResolver(registry)),
  recognizer: <a SpeechRecognizer impl>,    // speech_to_text-backed, see below
  synthesizer: <a SpeechSynthesizer impl>,  // flutter_tts-backed, see below
)
```

None of `RulesNlu`, `IntentExecutor`, or `DeviceResolver` were touched — they
already exist in `lib/assistant/`. What does **not** yet exist and needs to
be written (outside this boundary, so not done here):

- A `SpeechRecognizer` implementation over the `speech_to_text` package
  (already a pubspec dependency).
- A `SpeechSynthesizer` implementation over `flutter_tts` (already a pubspec
  dependency).
- A `WakeWordEngine` implementation (or two — Porcupine via
  `porcupine_flutter`, open engine via `sherpa_onnx`) for `enable()` to be
  called with. Until one exists, the assistant works fine in tap-to-talk /
  typed-command mode (`pushToTalk()` / `handleText()`), just never
  transitions out of `AssistantPhase.off` on its own.

## 2. Drop `AssistantFab` into the shell

`lib/widgets/assistant/assistant_fab.dart` exports `AssistantFab`, a small
`FloatingActionButton` meant for `Scaffold.floatingActionButton`. It was not
added to `home_shell.dart` (out of boundary). Suggested wiring:

```dart
// home_shell.dart
body: IndexedStack(index: _index, children: _screens),
floatingActionButton: const AssistantFab(),
bottomNavigationBar: NavigationBar(...),
```

`AssistantFab` needs no props — it reads phase from the provided
`AssistantService` itself. Tap opens `showAssistantSheet(context)`;
long-press calls `pushToTalk()` directly, skipping the sheet.

## 3. Wire `VoiceSettingsScreen` into Settings

`lib/screens/assistant/voice_settings_screen.dart` is intentionally
decoupled from `SettingsStore` — it takes a `VoiceSettingsData` value object
and an `onChanged(VoiceSettingsData)` callback, plus a separate
`onRequestMicPermission` callback. Nothing in `settings_screen.dart` was
touched to add a navigation entry.

Suggested wiring in `settings_screen.dart`, in the existing `Connections`
section pattern (a `ListTile` that pushes a `MaterialPageRoute`):

```dart
ListTile(
  leading: const Icon(Icons.mic_outlined),
  title: const Text('Voice assistant'),
  subtitle: Text(settings.assistantEnabled ? 'On' : 'Off'),
  trailing: const Icon(Icons.chevron_right),
  onTap: () => Navigator.push(
    context,
    MaterialPageRoute<void>(
      builder: (_) => VoiceSettingsScreen(
        data: VoiceSettingsData(
          assistantEnabled: settings.assistantEnabled,
          micPermission: /* map from permission_handler's Permission.microphone.status */,
          wakeEngine: settings.wakeEngine == 'porcupine'
              ? WakeEngineChoice.porcupine
              : WakeEngineChoice.openEngine,
          wakeWord: settings.wakeWord,
          picovoiceAccessKey: settings.picovoiceAccessKey,
          sensitivity: settings.wakeSensitivity,
          ttsEnabled: settings.ttsEnabled,
          ttsVolume: settings.ttsVolume,
        ),
        onChanged: (data) {
          settings.assistantEnabled = data.assistantEnabled;
          settings.wakeEngine = data.wakeEngine == WakeEngineChoice.porcupine
              ? 'porcupine' : 'openwakeword';
          settings.wakeWord = data.wakeWord;
          settings.picovoiceAccessKey = data.picovoiceAccessKey;
          settings.wakeSensitivity = data.sensitivity;
          settings.ttsEnabled = data.ttsEnabled;
          settings.ttsVolume = data.ttsVolume;
          // Then re-enable/reconfigure the running AssistantService as needed,
          // e.g. call assistantService.enable(...)/disable() on relevant changes.
        },
        onRequestMicPermission: () async {
          final result = await Permission.microphone.request();
          // rebuild with updated MicPermissionStatus
        },
      ),
    ),
  ),
),
```

This requires `SettingsStore` (in `lib/services/settings_store.dart`, out of
boundary) to grow the fields referenced above
(`assistantEnabled`, `wakeEngine`, `wakeWord`, `picovoiceAccessKey`,
`wakeSensitivity`, `ttsEnabled`, `ttsVolume`) — none of which exist there
yet. `VoiceSettingsScreen` doesn't care what they're called or how they're
persisted; it only needs a `VoiceSettingsData` in and a callback out.

## 4. `lowFx` is already respected

`AssistantSheet` and `ListeningIndicator` both read
`context.watch<SettingsStore>().lowFx` and skip the pulsing-ring animation
when it's true (matching how `theme.dart` strips transitions/splash for weak
hardware). No extra wiring needed here — `SettingsStore` is assumed to
already be provided app-wide, which it is today.

## 5. Files delivered

- `lib/screens/assistant/assistant_sheet.dart` — `showAssistantSheet(context)`
  + `AssistantSheet` widget.
- `lib/widgets/assistant/listening_indicator.dart` — `ListeningIndicator`.
- `lib/widgets/assistant/assistant_fab.dart` — `AssistantFab`.
- `lib/screens/assistant/voice_settings_screen.dart` — `VoiceSettingsScreen`,
  `VoiceSettingsData`, `WakeEngineChoice`, `MicPermissionStatus`.
- `test/screens/assistant/assistant_sheet_test.dart` — widget tests using a
  real `AssistantService` with fake `SpeechRecognizer`/`SpeechSynthesizer`
  and `RulesNlu` against an empty/small `DeviceRegistry`.
- `test/screens/assistant/voice_settings_screen_test.dart` — widget tests
  for the settings screen's controls against `VoiceSettingsData`.

Nothing outside `lib/screens/assistant/`, `lib/widgets/assistant/`, and
`test/screens/assistant/` was created or modified.
