import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_deck/screens/assistant/voice_settings_screen.dart';

/// [VoiceSettingsScreen] is a controlled component: it only ever renders
/// whatever `data` it's given. This wrapper plays the role of the
/// integrator — it applies every [VoiceSettingsData] the screen reports
/// back through [onChanged] to its own state (so the UI actually updates),
/// and forwards it to [spy] so tests can assert on it — the same round trip
/// real wiring (SettingsStore) would do.
///
/// [didUpdateWidget] re-seeds `data` whenever a test calls `pumpWidget`
/// again with a new [initial]: `tester.pumpWidget` reuses this State object
/// (same widget type/position) rather than recreating it, so without this,
/// `data`'s `late` initializer — which only runs once — would keep serving
/// the first test's stale value.
class _Harness extends StatefulWidget {
  const _Harness({required this.initial, this.spy, this.onRequest});

  final VoiceSettingsData initial;
  final ValueChanged<VoiceSettingsData>? spy;
  final VoidCallback? onRequest;

  @override
  State<_Harness> createState() => _HarnessState();
}

class _HarnessState extends State<_Harness> {
  late VoiceSettingsData data = widget.initial;

  @override
  void didUpdateWidget(covariant _Harness oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.initial, widget.initial)) {
      data = widget.initial;
    }
  }

  @override
  Widget build(BuildContext context) => MaterialApp(
        home: VoiceSettingsScreen(
          data: data,
          onChanged: (next) {
            setState(() => data = next);
            widget.spy?.call(next);
          },
          onRequestMicPermission: widget.onRequest ?? () {},
        ),
      );
}

void main() {
  // The screen's body is a ListView, which only builds children inside its
  // viewport — the default test surface (~800x600) is shorter than the
  // full settings list, so anything below "Mic permission" (the wake-word
  // engine picker, the wake-word field, the sliders) silently doesn't exist
  // in the widget tree without this. A tall fixed surface avoids every test
  // having to scroll to reach what it wants to assert on or interact with.
  Future<void> useTallSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 3000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
  }

  const initial = VoiceSettingsData(
    assistantEnabled: false,
    micPermission: MicPermissionStatus.notRequested,
    wakeEngine: WakeEngineChoice.openEngine,
    wakeWord: 'hey jarvis',
    picovoiceAccessKey: '',
    sensitivity: 0.5,
    ttsEnabled: false,
    ttsVolume: 0.8,
  );

  testWidgets('toggling the assistant switch reports the new value', (tester) async {
    await useTallSurface(tester);
    VoiceSettingsData? updated;
    await tester.pumpWidget(_Harness(initial: initial, spy: (d) => updated = d));

    await tester.tap(find.widgetWithText(SwitchListTile, 'Voice assistant'));
    await tester.pumpAndSettle();

    expect(updated?.assistantEnabled, isTrue);
  });

  testWidgets('mic permission row: Request calls the callback and disappears once granted',
      (tester) async {
    await useTallSurface(tester);
    var requested = false;
    await tester.pumpWidget(
      _Harness(initial: initial, onRequest: () => requested = true),
    );

    expect(find.text('Request'), findsOneWidget);
    await tester.tap(find.text('Request'));
    expect(requested, isTrue);

    await tester.pumpWidget(
      _Harness(
        initial: initial.copyWith(micPermission: MicPermissionStatus.granted),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Request'), findsNothing);
    expect(find.textContaining('Granted'), findsOneWidget);
  });

  testWidgets('selecting Porcupine reveals the AccessKey field and swaps the wake-word hint',
      (tester) async {
    await useTallSurface(tester);
    await tester.pumpWidget(_Harness(initial: initial));

    expect(find.byKey(const Key('picovoiceAccessKeyField')), findsNothing);
    expect(
      tester.widget<TextField>(find.byKey(const Key('wakeWordField'))).decoration?.hintText,
      'Typed keyword, e.g. "hey jarvis"',
    );

    await tester.tap(find.text('Porcupine (needs free Picovoice key)'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('picovoiceAccessKeyField')), findsOneWidget);
    expect(
      tester.widget<TextField>(find.byKey(const Key('wakeWordField'))).decoration?.hintText,
      'Path to a .ppn model file',
    );
  });

  testWidgets('AccessKey field is obscured and echoes typed text upward',
      (tester) async {
    await useTallSurface(tester);
    VoiceSettingsData? updated;
    await tester.pumpWidget(
      _Harness(
        initial: initial.copyWith(wakeEngine: WakeEngineChoice.porcupine),
        spy: (d) => updated = d,
      ),
    );

    final keyField = find.byKey(const Key('picovoiceAccessKeyField'));
    expect(tester.widget<TextField>(keyField).obscureText, isTrue);

    await tester.enterText(keyField, 'sk-test-key');
    await tester.pump();

    expect(updated?.picovoiceAccessKey, 'sk-test-key');
  });

  testWidgets('typing a wake word propagates through onChanged', (tester) async {
    await useTallSurface(tester);
    VoiceSettingsData? updated;
    await tester.pumpWidget(_Harness(initial: initial, spy: (d) => updated = d));

    await tester.enterText(find.byKey(const Key('wakeWordField')), 'hey computer');
    await tester.pump();

    expect(updated?.wakeWord, 'hey computer');
  });

  testWidgets('TTS toggle reveals the volume slider', (tester) async {
    await useTallSurface(tester);
    await tester.pumpWidget(_Harness(initial: initial));

    expect(find.byKey(const Key('sensitivitySlider')), findsOneWidget);
    expect(find.byKey(const Key('ttsVolumeSlider')), findsNothing);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Speak replies'));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('sensitivitySlider')), findsOneWidget);
    expect(find.byKey(const Key('ttsVolumeSlider')), findsOneWidget);
  });

  testWidgets('dragging the sensitivity slider reports a changed value',
      (tester) async {
    await useTallSurface(tester);
    VoiceSettingsData? updated;
    await tester.pumpWidget(_Harness(initial: initial, spy: (d) => updated = d));

    await tester.drag(find.byKey(const Key('sensitivitySlider')), const Offset(80, 0));
    await tester.pumpAndSettle();

    expect(updated, isNotNull);
    expect(updated!.sensitivity, isNot(initial.sensitivity));
  });
}
