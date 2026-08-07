import 'package:flutter_test/flutter_test.dart';
import 'package:home_deck/assistant/voice/impl/stt_recognizer.dart';

// speech_to_text's `initialize()` requires a real platform implementation to
// ever return true, and permission_handler needs a platform channel too —
// neither is available in a widget-free unit test. What's testable without
// either is the fail-soft path: no permission/no platform means `available`
// comes back false and `listen()` closes its stream without a final result,
// exactly like `cancel()`, per the class's documented behavior. This is also
// the actual behavior a plain `flutter test` run sees today, so it doubles
// as a regression check for "never hang, never throw" when the plugin isn't
// wired up.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    // No mock handler registered for permission_handler's channel: calls
    // fail, which is what a real device with no platform binding would also
    // do — permission_handler surfaces that as "not granted" rather than
    // throwing across the channel boundary in recent versions, but either
    // way `available` must resolve to false rather than hang.
  });

  test('available is false with no platform channels wired up', () async {
    final recognizer = SttSpeechRecognizer();
    final available = await recognizer.available;
    expect(available, isFalse);
    expect(recognizer.lastError, isNotNull);
  });

  test('available is cached across repeated calls', () async {
    final recognizer = SttSpeechRecognizer();
    final first = await recognizer.available;
    final second = await recognizer.available;
    expect(second, equals(first));
  });

  test('listen() closes without a final result when unavailable', () async {
    final recognizer = SttSpeechRecognizer();
    final results = await recognizer.listen().toList();
    expect(results, isEmpty);
  });

  test('cancel() before any listen() is a harmless no-op', () async {
    final recognizer = SttSpeechRecognizer();
    await expectLater(recognizer.cancel(), completes);
  });
}
