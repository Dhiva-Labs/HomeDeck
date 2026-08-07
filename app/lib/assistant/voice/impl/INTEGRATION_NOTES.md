# Voice I/O layer — integration notes

Everything in this directory implements the abstract classes in
`../voice_interfaces.dart` exactly as written; nothing there changed. This
file lists the follow-up wiring that lives outside this directory's file
boundary, so it's written down instead of done directly.

## 1. `pubspec.yaml` — sherpa-onnx KWS model assets

`sherpa_kws_engine.dart` loads four files via `rootBundle.load()`:

```
assets/kws/encoder.onnx
assets/kws/decoder.onnx
assets/kws/joiner.onnx
assets/kws/tokens.txt
```

These are **not currently declared** as Flutter assets (pubspec.yaml wasn't
touched, per the file boundary for this task), and the files don't exist in
the repo yet. Until both are true, `SherpaKwsWakeWordEngine.start()` fails
soft: `lastError` is set and an `'error: ...'` event is pushed on `status`,
`running` stays `false`, nothing throws.

To make this engine usable:

1. Add a streaming Zipformer2 transducer KWS model (encoder/decoder/joiner
   + tokens) under `app/assets/kws/` with exactly those four file names —
   e.g. one of the pretrained keyword-spotting models from the
   [sherpa-onnx model zoo](https://github.com/k2-fsa/sherpa-onnx). These
   models are typically 15-25 MB combined; consider whether they belong in
   the repo or in a downloaded-on-first-run flow given the "old hardware"
   target.
2. Add to `pubspec.yaml`:
   ```yaml
   flutter:
     assets:
       - assets/kws/
   ```

## 2. The `keywordAsset` string for `SherpaKwsWakeWordEngine`

Per the task spec, `keywordAsset` for this engine is "the user's custom
wake name transliterated" — but sherpa-onnx's `KeywordSpotter.createStream
(keywords: ...)` does **not** take plain English text. It expects a
`keywords.txt`-style line: space-separated modeling-unit tokens matching
the loaded model's vocabulary, e.g.

```
HH EY1 JH AA1 R V AH0 S @hey jarvis :1.5
```

(tokens, optional `@comment`, optional `:boost-score`). Producing that from
a user-typed phrase requires a grapheme-to-phoneme/BPE step keyed to the
specific model's `tokens.txt`, which this layer doesn't own (it has no
access to the model's token list at the settings-UI layer where the phrase
is typed). This file passes whatever string it's given straight through to
`createStream`, unmodified — the transliteration has to happen upstream,
most likely in the same onboarding screen that currently only handles
Porcupine's `.ppn`/built-in-keyword picker. Until that exists, treat this
engine as functional-but-untriggerable without a hand-built keywords line
for testing.

## 3. Wiring into the app

No file outside this directory constructs these classes yet (`main.dart`,
`settings_store.dart`, and the assistant screens were all off-limits for
this task). The engines a caller will want:

- `PorcupineWakeWordEngine(accessKey: <from SettingsStore>, modelPath: null)`
- `SherpaKwsWakeWordEngine()`
- `SttSpeechRecognizer()`
- `FlutterTtsSynthesizer()`

All four are safe to construct eagerly (no native work happens until
`start()`/`listen()`/`speak()`). `PorcupineWakeWordEngine` and
`SherpaKwsWakeWordEngine` each expose a `Stream<String> status` and a
`String? lastError` getter beyond the `WakeWordEngine` interface — bind
`status` to whatever UI shows wake-word setup state (the "Test" screen in
the spec's onboarding flow, and the mic glyph's error state).

Switching engines: call `await current.stop()` (not `dispose()`) before
calling `start()` on the other engine — `stop()` fully releases the mic on
both implementations, which is what makes the hand-off safe. Reserve
`dispose()` for when the engine won't be used again (e.g. app shutdown or
the user switches away from that engine permanently in Settings), since it
frees native memory the engine would otherwise need to reload.

## 4. AndroidManifest.xml permissions added

- `RECORD_AUDIO` — required by all three plugins that touch the mic
  (`porcupine_flutter`/its bundled voice processor, `record`,
  `speech_to_text`).
- `BLUETOOTH_CONNECT` — `speech_to_text`'s README lists this as required
  for Bluetooth headset input on Android 12+ (API 31+, `targetSdkVersion`
  in this app). It's a runtime-requested permission on those OS versions,
  so it's inert on the minSdk 21 devices this app otherwise targets.

**Not added:** `speech_to_text`'s README also lists the legacy
`BLUETOOTH`/`BLUETOOTH_ADMIN` permissions for headset support on
pre-Android-12 devices. The task scoped this file's edit to
`RECORD_AUDIO` + `BLUETOOTH_CONNECT` only ("nothing else"), so those two
were left out. If BT headset mic input needs to work on the older/API<31
devices this app targets, add them:
```xml
<uses-permission android:name="android.permission.BLUETOOTH"/>
<uses-permission android:name="android.permission.BLUETOOTH_ADMIN"/>
```
No foreground-service permission was added: nothing in this layer runs a
foreground service (wake-word listening currently only runs while the app
is in the foreground). If "listening continues while the screen is dim"
from the spec ends up needing a foreground service to survive OS
background limits, that's a separate addition
(`FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MICROPHONE`, API 34+ requires
the latter) alongside an actual `Service` implementation, neither of which
exists yet.

## 5. Porcupine built-in keyword matching

`PorcupineWakeWordEngine._matchBuiltIn` accepts `keywordAsset` values like
`"jarvis"`, `"Hey Google"`, or `"HEY_GOOGLE"` and matches them against
`BuiltInKeyword` case/spacing-insensitively. Anything that doesn't match a
built-in name is treated as a path to a custom `.ppn` file. There's no
validation that a non-matching string is actually a valid file path — that
surfaces as an `'error: ...'` on `status` from Porcupine itself when
`start()` can't open it.

## 6. Testing scope

Per the task, tests avoid real mic/platform channels. `test/assistant/voice/`
covers:
- `stt_recognizer_test.dart` — behavior around a fake/mocked
  `speech_to_text` surface isn't feasible without the plugin's platform
  interface test harness, so this is a construction smoke test plus a
  focused test of the pure logic that doesn't need the plugin (pause-for
  clamping).
- `tts_synthesizer_test.dart` — drives `FlutterTtsSynthesizer` against a
  fake `FlutterTts`-shaped completion/error callback sequence via the
  constructor's injectable `tts` parameter, verifying `speak()` resolves
  on the completion handler and on the error handler, and that a second
  `speak()` doesn't resolve from a stale completer.
- `porcupine_engine_smoke_test.dart` / `sherpa_kws_engine_smoke_test.dart`
  — construct the class and assert the interface surface (`id`, `label`,
  `running == false`) without touching native code, plus verify
  `SherpaKwsWakeWordEngine.start()` fails soft (no throw, `running` stays
  `false`, `lastError` set) when the KWS assets aren't bundled, which is
  the actual state of this repo right now.
