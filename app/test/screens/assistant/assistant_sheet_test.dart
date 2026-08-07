import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_deck/assistant/assistant_service.dart';
import 'package:home_deck/models/device.dart';
import 'package:home_deck/screens/assistant/assistant_sheet.dart';
import 'package:home_deck/services/settings_store.dart';
import 'package:provider/provider.dart';

import 'test_support.dart';

/// All these tests pin `lowFx: true`. That both matches the constraint that
/// the sheet must respect the flag, and — just as important for a widget
/// test — it keeps `ListeningIndicator`'s `AnimationController.repeat()`
/// from ever starting, so `pumpAndSettle()` can be used safely (an unbounded
/// repeating animation would otherwise mean it never settles). The
/// animation itself is covered separately in listening_indicator_test.dart.
///
/// Tests that drive the recognizer/synthesizer/connector fakes go through
/// `runUntilPhase`/`runAsyncUntil` (see test_support.dart) rather than
/// `pushToTalk()` via a UI tap: `AssistantService`'s pipeline is built on
/// `StreamController` and `Completer`, and empirically their continuations
/// don't get flushed by `tester.pump()`'s fake-clock draining once the
/// triggering call (recognizer.listen()) happened under a plain widget tap.
/// Calling `pushToTalk()` itself from inside the same real `runAsync` zone
/// as every subsequent trigger sidesteps that entirely. The mic button's
/// own wiring (that tapping it calls `pushToTalk`) is covered by the first
/// test below, which only needs the phase to move off `off` — no streamed
/// events involved, so a plain tap is reliable for that much.
void main() {
  Widget harness({
    required AssistantService service,
    required SettingsStore settings,
  }) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider<AssistantService>.value(value: service),
        ChangeNotifierProvider<SettingsStore>.value(value: settings),
      ],
      child: MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () => showAssistantSheet(context),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('off phase: muted label shown, typed command still works',
      (tester) async {
    final harnessData = AssistantTestHarness(devices: [deskLamp()]);
    final settings = await buildSettingsStore(lowFx: true);
    await tester.pumpWidget(
      harness(service: harnessData.service, settings: settings),
    );
    await flushRegistrySaveTimer(tester);

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(harnessData.service.phase, AssistantPhase.off);
    expect(find.textContaining('Assistant off'), findsOneWidget);

    await tester.enterText(find.byType(TextField), 'turn on the desk lamp');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(find.text('Turned on Desk Lamp.'), findsOneWidget);
    expect(find.widgetWithText(Chip, 'Desk Lamp'), findsOneWidget);
    // Text command executes even though the assistant was never enabled.
    expect(harnessData.service.phase, AssistantPhase.off);
  });

  testWidgets('tapping the mic moves the phase off "off" (basic wiring check)',
      (tester) async {
    final harnessData = AssistantTestHarness(devices: [deskLamp()]);
    final settings = await buildSettingsStore(lowFx: true);
    await tester.pumpWidget(
      harness(service: harnessData.service, settings: settings),
    );
    await flushRegistrySaveTimer(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('assistantMicButton')));
    await tester.pumpAndSettle();

    expect(harnessData.service.phase, AssistantPhase.listening);
    expect(find.text('Listening…'), findsWidgets);
  });

  testWidgets(
      'listening -> acting -> responding -> off: transcript, confirmation and device chip',
      (tester) async {
    final harnessData = AssistantTestHarness(devices: [deskLamp()]);
    final settings = await buildSettingsStore(lowFx: true);
    await tester.pumpWidget(
      harness(service: harnessData.service, settings: settings),
    );
    await flushRegistrySaveTimer(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await runUntilPhase(
      tester,
      harnessData.service,
      AssistantPhase.listening,
      trigger: () => unawaited(harnessData.service.pushToTalk()),
    );
    await tester.pump();
    expect(find.text('Listening…'), findsWidgets);

    await runAsyncUntil(
      tester,
      () => harnessData.service.transcript == 'turn on the desk',
      trigger: () => harnessData.recognizer.emitPartial('turn on the desk'),
    );
    await tester.pump();
    expect(find.text('"turn on the desk"'), findsOneWidget);

    // No gates were set, so acting -> responding -> back to off all
    // resolve as part of the same wait.
    await runUntilPhase(
      tester,
      harnessData.service,
      AssistantPhase.off,
      trigger: () => harnessData.recognizer.emitFinal('turn on the desk lamp'),
    );
    await tester.pump();

    expect(find.textContaining('Turned on Desk Lamp'), findsOneWidget);
    expect(find.widgetWithText(Chip, 'Desk Lamp'), findsOneWidget);
  });

  testWidgets('acting phase renders while the connector call is pending',
      (tester) async {
    final connectorGate = Completer<void>();
    final harnessData = AssistantTestHarness(
      devices: [deskLamp()],
      connectorGate: connectorGate,
    );
    final settings = await buildSettingsStore(lowFx: true);
    await tester.pumpWidget(
      harness(service: harnessData.service, settings: settings),
    );
    await flushRegistrySaveTimer(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await runUntilPhase(
      tester,
      harnessData.service,
      AssistantPhase.listening,
      trigger: () => unawaited(harnessData.service.pushToTalk()),
    );
    await tester.pump();

    await runUntilPhase(
      tester,
      harnessData.service,
      AssistantPhase.acting,
      trigger: () => harnessData.recognizer.emitFinal('turn on the desk lamp'),
    );
    await tester.pump();

    expect(find.text('Working…'), findsOneWidget);

    await runUntilPhase(
      tester,
      harnessData.service,
      AssistantPhase.off,
      trigger: connectorGate.complete,
    );
    await tester.pump();

    expect(find.textContaining('Turned on Desk Lamp'), findsOneWidget);
  });

  testWidgets(
      'responding phase renders the reply banner and device chip before TTS finishes (query keeps speaking)',
      (tester) async {
    final speakGate = Completer<void>();
    final harnessData = AssistantTestHarness(devices: [deskLamp()]);
    harnessData.synthesizer.gate = speakGate;
    final settings = await buildSettingsStore(lowFx: true);
    await tester.pumpWidget(
      harness(service: harnessData.service, settings: settings),
    );
    await flushRegistrySaveTimer(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await runUntilPhase(
      tester,
      harnessData.service,
      AssistantPhase.listening,
      trigger: () => unawaited(harnessData.service.pushToTalk()),
    );
    await tester.pump();

    await runUntilPhase(
      tester,
      harnessData.service,
      AssistantPhase.responding,
      trigger: () => harnessData.recognizer.emitFinal('is the desk lamp on'),
    );
    await tester.pump();

    expect(find.text('Responding…'), findsOneWidget);
    expect(find.textContaining('Desk Lamp is'), findsOneWidget);
    expect(find.widgetWithText(Chip, 'Desk Lamp'), findsOneWidget);
    // ok result uses the check icon, not the error one.
    expect(find.byIcon(Icons.check_circle_outline), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsNothing);

    await runUntilPhase(
      tester,
      harnessData.service,
      AssistantPhase.off,
      trigger: speakGate.complete,
    );
    await tester.pump();
  });

  testWidgets('a failed command is styled with the error icon', (tester) async {
    final harnessData = AssistantTestHarness(devices: [deskLamp()]);
    final settings = await buildSettingsStore(lowFx: true);
    await tester.pumpWidget(
      harness(service: harnessData.service, settings: settings),
    );
    await flushRegistrySaveTimer(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
      find.byType(TextField),
      'turn on the nonexistent gadget',
    );
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(harnessData.service.lastResult?.ok, isFalse);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    expect(find.byIcon(Icons.check_circle_outline), findsNothing);
  });

  testWidgets(
      'ambiguous match shows "Which one?" chips; tapping one resolves it',
      (tester) async {
    // Same-kind multi-matches now act on the whole group (the Google
    // Assistant contract), so the ambiguous path needs MIXED kinds: "the
    // sofa" matching a light and an outlet is a real "which one?" — acting
    // on a guess would actuate the wrong class of hardware.
    final sofaLamp = Device(
      id: 'gated:1',
      connectorId: 'gated',
      name: 'Sofa Lamp',
      kind: DeviceKind.light,
      capabilities: const {DeviceCapability.toggle},
    );
    final shelfLamp = Device(
      id: 'gated:2',
      connectorId: 'gated',
      name: 'Sofa Heater',
      kind: DeviceKind.outlet,
      capabilities: const {DeviceCapability.toggle},
    );
    final harnessData = AssistantTestHarness(devices: [sofaLamp, shelfLamp]);
    final settings = await buildSettingsStore(lowFx: true);
    await tester.pumpWidget(
      harness(service: harnessData.service, settings: settings),
    );
    await flushRegistrySaveTimer(tester);
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), 'turn on the sofa');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await tester.pumpAndSettle();

    expect(harnessData.service.lastResult?.needsDisambiguation, isTrue);
    expect(find.text('Which one?'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Sofa Lamp'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, 'Sofa Heater'), findsOneWidget);

    await tester.tap(find.widgetWithText(ActionChip, 'Sofa Lamp'));
    await tester.pumpAndSettle();

    expect(harnessData.service.lastResult?.needsDisambiguation, isFalse);
    expect(find.textContaining('Turned on Sofa Lamp'), findsOneWidget);
    expect(find.text('Which one?'), findsNothing);
  });
}
