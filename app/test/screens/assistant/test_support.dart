// Shared fakes for the assistant widget tests. Not itself a `_test.dart`
// file, so the test runner ignores it as a suite; it's imported by the
// suites in this directory.
//
// The fakes implement the small interfaces AssistantService depends on
// (`SpeechRecognizer`, `SpeechSynthesizer`, `WakeWordEngine` from
// lib/assistant/voice/voice_interfaces.dart, and a minimal `Connector`),
// so tests can drive a *real* `AssistantService` — same NLU (`RulesNlu`),
// same `IntentExecutor`/`DeviceResolver` — end to end, and freeze it at a
// chosen phase by holding a `Completer` open.
import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:home_deck/assistant/assistant_service.dart';
import 'package:home_deck/assistant/device_resolver.dart';
import 'package:home_deck/assistant/intent_executor.dart';
import 'package:home_deck/assistant/nlu/rules_nlu.dart';
import 'package:home_deck/assistant/voice/voice_interfaces.dart';
import 'package:home_deck/connectors/connector.dart';
import 'package:home_deck/models/device.dart';
import 'package:home_deck/services/connectors_service.dart';
import 'package:home_deck/services/device_capabilities.dart';
import 'package:home_deck/services/device_registry.dart';
import 'package:home_deck/services/settings_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A [SpeechRecognizer] the test drives by hand: [emitPartial]/[emitFinal]
/// push results into whatever stream the most recent [listen] call handed
/// out, standing in for real STT.
class FakeRecognizer implements SpeechRecognizer {
  StreamController<SttResult>? _controller;
  bool cancelled = false;

  @override
  Stream<SttResult> listen({Duration timeout = const Duration(seconds: 8)}) {
    cancelled = false;
    final controller = StreamController<SttResult>();
    _controller = controller;
    return controller.stream;
  }

  void emitPartial(String text) =>
      _controller?.add(SttResult(text, isFinal: false));

  void emitFinal(String text) => _controller?.add(SttResult(text, isFinal: true));

  @override
  Future<void> cancel() async {
    cancelled = true;
    await _controller?.close();
  }

  @override
  Future<bool> get available async => true;
}

/// A [SpeechSynthesizer] that records what it was asked to say. Setting
/// [gate] to an open [Completer] makes [speak] hang until the test
/// completes it — the way to freeze [AssistantPhase.responding] for
/// inspection.
class FakeSynthesizer implements SpeechSynthesizer {
  final List<String> spoken = [];
  Completer<void>? gate;

  @override
  Future<void> speak(String text) async {
    spoken.add(text);
    final g = gate;
    if (g != null) await g.future;
  }

  @override
  Future<void> stopSpeaking() async {}

  @override
  set volume(double v) {}
}

/// Inert [WakeWordEngine] — none of these tests fire a wake detection (they
/// drive the pipeline via `pushToTalk`/`handleText`), but `enable()` needs
/// something to hold.
class FakeWakeEngine implements WakeWordEngine {
  bool _running = false;
  final _detections = StreamController<void>.broadcast();

  @override
  String get id => 'fake';

  @override
  String get label => 'Fake';

  @override
  Stream<void> get detections => _detections.stream;

  @override
  bool get running => _running;

  @override
  Future<void> start({
    required String keywordAsset,
    double sensitivity = 0.5,
  }) async {
    _running = true;
  }

  @override
  Future<void> stop() async {
    _running = false;
  }

  @override
  Future<void> dispose() async {
    await _detections.close();
  }
}

/// A [Connector] whose [invoke] can be gated open with a [Completer], so a
/// test can freeze [AssistantPhase.acting] for inspection before letting the
/// action "complete".
class GatedConnector extends Connector {
  GatedConnector(super.registry, {this.gate});

  final Completer<void>? gate;
  final List<DeviceAction> invoked = [];

  @override
  String get id => 'gated';

  @override
  String get label => 'Gated';

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}

  @override
  Future<void> refresh() async {}

  @override
  Future<void> invoke(Device device, DeviceAction action) async {
    invoked.add(action);
    final g = gate;
    if (g != null) await g.future;
  }
}

/// A real [AssistantService] wired to fakes, plus handles on those fakes so
/// a test can push STT results and release gates. All test devices should
/// use `connectorId: 'gated'` to route through [GatedConnector].
class AssistantTestHarness {
  AssistantTestHarness({
    List<Device> devices = const [],
    Completer<void>? connectorGate,
  })  : registry = DeviceRegistry(),
        recognizer = FakeRecognizer(),
        synthesizer = FakeSynthesizer() {
    registry.upsertAll(devices);
    final connectors =
        ConnectorsService([GatedConnector(registry, gate: connectorGate)]);
    service = AssistantService(
      registry: registry,
      nlu: const RulesNlu(),
      executor: IntentExecutor(connectors, DeviceResolver(registry)),
      recognizer: recognizer,
      synthesizer: synthesizer,
    );
  }

  final DeviceRegistry registry;
  final FakeRecognizer recognizer;
  final FakeSynthesizer synthesizer;
  late final AssistantService service;
}

/// A real [SettingsStore] backed by mocked SharedPreferences, pinned to
/// [lowFx] via [PerformanceMode.on]/[PerformanceMode.off] so tests don't
/// depend on (or need to fake) hardware detection.
Future<SettingsStore> buildSettingsStore({required bool lowFx}) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  final store = SettingsStore(
    prefs,
    const DeviceCapabilities(isWeak: false, reason: 'test'),
  );
  store.performanceMode = lowFx ? PerformanceMode.on : PerformanceMode.off;
  return store;
}

/// Drives real async work outside Flutter's `FakeAsync` test clock, then
/// polls [condition] until it's true.
///
/// `AssistantService`'s pipeline is built on `StreamController` (the
/// recognizer) and `Completer` (the connector/TTS gates); empirically, that
/// event delivery does not get flushed by `tester.pump()`'s fake-clock
/// microtask draining inside `testWidgets` — `WidgetTester.runAsync` is the
/// documented escape hatch for exactly this (real Futures/Streams that
/// don't cooperate with `FakeAsync`). Call [trigger] (e.g.
/// `recognizer.emitFinal(...)`, or nothing to just wait out a gate already
/// released) inside that real zone, then poll until [condition] holds.
///
/// Always follow this with a `tester.pump()` to rebuild the widget tree
/// against the now-settled state.
Future<void> runAsyncUntil(
  WidgetTester tester,
  bool Function() condition, {
  VoidCallback? trigger,
  Duration timeout = const Duration(seconds: 5),
}) {
  return tester.runAsync(() async {
    trigger?.call();
    final deadline = DateTime.now().add(timeout);
    while (!condition()) {
      if (DateTime.now().isAfter(deadline)) {
        throw TimeoutException(
          'runAsyncUntil: condition not met within $timeout',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 1));
    }
  });
}

/// Convenience [runAsyncUntil] for the common case of waiting for a phase.
Future<void> runUntilPhase(
  WidgetTester tester,
  AssistantService service,
  AssistantPhase phase, {
  VoidCallback? trigger,
}) =>
    runAsyncUntil(tester, () => service.phase == phase, trigger: trigger);

/// `DeviceRegistry.upsertAll` (called by [AssistantTestHarness]'s
/// constructor, even for an empty device list) queues a real
/// `Future.delayed(Duration(seconds: 2))` disk-save. Flutter's test binding
/// runs each test inside a `FakeAsync` zone, where that timer only fires
/// once fake time is advanced past it — leaving it unfired trips the
/// "Timer is still pending" assertion at test teardown. Call this once
/// after `pumpWidget` in any test that builds an [AssistantTestHarness], to
/// flush it (the save itself is a no-op in tests: there's no backing file).
Future<void> flushRegistrySaveTimer(WidgetTester tester) =>
    tester.pump(const Duration(seconds: 3));

Device deskLamp({String room = 'Bedroom'}) => Device(
      id: 'gated:desk-lamp',
      connectorId: 'gated',
      name: 'Desk Lamp',
      kind: DeviceKind.light,
      room: room,
      state: {'on': false},
      capabilities: {DeviceCapability.toggle},
    );
