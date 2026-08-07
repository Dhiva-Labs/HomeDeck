import 'package:flutter_test/flutter_test.dart';
import 'package:home_deck/assistant/voice/impl/sherpa_kws_engine.dart';

// The real path here touches native FFI (sherpa-onnx), a platform channel
// (permission_handler) and Flutter asset loading — none of which are wired
// up in a widget-free unit test, and the KWS model assets aren't bundled in
// this repo yet regardless (see INTEGRATION_NOTES.md). That makes the
// fail-soft contract the thing worth testing: start() must never throw and
// must leave `running` false when any of those are missing, which is
// exactly the state this repo is in today.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('exposes id/label and starts not running', () {
    final engine = SherpaKwsWakeWordEngine();
    expect(engine.id, 'sherpa_kws');
    expect(engine.label, isNotEmpty);
    expect(engine.running, isFalse);
  });

  test('start() fails soft on an empty keywords string', () async {
    final engine = SherpaKwsWakeWordEngine();
    await expectLater(
      engine.start(keywordAsset: ''),
      completes,
    );
    expect(engine.running, isFalse);
    expect(engine.lastError, contains('empty'));
  });

  test(
      'start() fails soft (no throw, not running, error surfaced) when '
      'models/permissions/native bindings are unavailable', () async {
    final engine = SherpaKwsWakeWordEngine();
    final statuses = <String>[];
    final sub = engine.status.listen(statuses.add);

    await expectLater(
      engine.start(keywordAsset: 'HH EY1 JH AA1 R V AH0 S'),
      completes,
    );
    // status is a broadcast stream; give its microtask a turn to deliver
    // before asserting on what the listener collected.
    await Future<void>.delayed(Duration.zero);

    expect(engine.running, isFalse);
    expect(engine.lastError, isNotNull);
    expect(statuses, isNotEmpty);
    expect(statuses.every((s) => s.startsWith('error:')), isTrue);

    await sub.cancel();
    await engine.dispose();
  });

  test('stop() before start() is a harmless no-op', () async {
    final engine = SherpaKwsWakeWordEngine();
    await expectLater(engine.stop(), completes);
    expect(engine.running, isFalse);
  });

  test('dispose() before start() is a harmless no-op', () async {
    final engine = SherpaKwsWakeWordEngine();
    await expectLater(engine.dispose(), completes);
  });
}
