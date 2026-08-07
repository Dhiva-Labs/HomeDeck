import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_deck/assistant/assistant_service.dart';
import 'package:home_deck/widgets/assistant/listening_indicator.dart';

void main() {
  Widget harness(AssistantPhase phase, bool lowFx) => MaterialApp(
        home: Scaffold(
          body: Center(child: ListeningIndicator(phase: phase, lowFx: lowFx)),
        ),
      );

  Finder ring() => find.descendant(
        of: find.byType(ListeningIndicator),
        matching: find.byType(Transform),
      );

  // Not `getMaxScaleOnAxis()`: `Transform.scale` only touches the X/Y
  // diagonal, leaving Z at a constant 1.0 — which `getMaxScaleOnAxis()`
  // then reports as "the" scale forever, masking any real X/Y change.
  // `storage[0]` is the matrix's (0,0) element, i.e. the actual X scale.
  double scaleOf(Finder finder, WidgetTester tester) =>
      tester.widget<Transform>(finder).transform.storage[0];

  testWidgets('no pulsing ring outside the listening phase', (tester) async {
    await tester.pumpWidget(harness(AssistantPhase.idle, false));
    await tester.pumpAndSettle();
    expect(ring(), findsNothing);
  });

  testWidgets('ring is present but static when lowFx is true, even while listening',
      (tester) async {
    await tester.pumpWidget(harness(AssistantPhase.listening, true));
    await tester.pump();
    final scale1 = scaleOf(ring(), tester);

    await tester.pump(const Duration(milliseconds: 700));
    final scale2 = scaleOf(ring(), tester);

    // Safe to settle: lowFx means the AnimationController never repeats,
    // so there's no unbounded frame stream to hang pumpAndSettle.
    await tester.pumpAndSettle();

    expect(scale2, closeTo(scale1, 0.0001));
  });

  testWidgets('ring pulses over time while listening without lowFx', (tester) async {
    await tester.pumpWidget(harness(AssistantPhase.listening, false));
    await tester.pump();
    final scale1 = scaleOf(ring(), tester);

    await tester.pump(const Duration(milliseconds: 700));
    final scale2 = scaleOf(ring(), tester);

    expect((scale2 - scale1).abs(), greaterThan(0.01));
    // Deliberately not calling pumpAndSettle here — the ring repeats
    // indefinitely in this configuration, which would hang it.
  });

  testWidgets('switching from listening to idle stops the animation', (tester) async {
    final key = GlobalKey();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ListeningIndicator(
              key: key,
              phase: AssistantPhase.listening,
              lowFx: false,
            ),
          ),
        ),
      ),
    );
    await tester.pump();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ListeningIndicator(
              key: key,
              phase: AssistantPhase.idle,
              lowFx: false,
            ),
          ),
        ),
      ),
    );

    // Now safe to settle: the phase change stops the repeating controller.
    await tester.pumpAndSettle();
    expect(ring(), findsNothing);
  });
}
