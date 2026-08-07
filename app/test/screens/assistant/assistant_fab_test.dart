import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_deck/assistant/assistant_service.dart';
import 'package:home_deck/screens/assistant/assistant_sheet.dart';
import 'package:home_deck/services/settings_store.dart';
import 'package:home_deck/widgets/assistant/assistant_fab.dart';
import 'package:provider/provider.dart';

import 'test_support.dart';

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
      child: const MaterialApp(
        home: Scaffold(floatingActionButton: AssistantFab()),
      ),
    );
  }

  testWidgets('shows the muted icon while the assistant is off', (tester) async {
    final harnessData = AssistantTestHarness();
    final settings = await buildSettingsStore(lowFx: true);
    await tester.pumpWidget(
      harness(service: harnessData.service, settings: settings),
    );
    await flushRegistrySaveTimer(tester);

    expect(harnessData.service.phase, AssistantPhase.off);
    expect(find.byIcon(Icons.mic_off_outlined), findsOneWidget);
    expect(find.byIcon(Icons.mic_outlined), findsNothing);
  });

  testWidgets('tap opens the assistant sheet', (tester) async {
    final harnessData = AssistantTestHarness();
    final settings = await buildSettingsStore(lowFx: true);
    await tester.pumpWidget(
      harness(service: harnessData.service, settings: settings),
    );
    await flushRegistrySaveTimer(tester);

    await tester.tap(find.byType(AssistantFab));
    await tester.pumpAndSettle();

    expect(find.byType(AssistantSheet), findsOneWidget);
  });

  testWidgets('long-press starts listening immediately, without opening the sheet',
      (tester) async {
    final harnessData = AssistantTestHarness();
    final settings = await buildSettingsStore(lowFx: true);
    await tester.pumpWidget(
      harness(service: harnessData.service, settings: settings),
    );
    await flushRegistrySaveTimer(tester);

    await tester.longPress(find.byType(AssistantFab));
    await tester.pumpAndSettle();

    expect(harnessData.service.phase, AssistantPhase.listening);
    expect(find.byType(AssistantSheet), findsNothing);
  });
}
