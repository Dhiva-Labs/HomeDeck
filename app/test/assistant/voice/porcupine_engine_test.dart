import 'package:flutter_test/flutter_test.dart';
import 'package:porcupine_flutter/porcupine.dart';
import 'package:home_deck/assistant/voice/impl/porcupine_engine.dart';

// PorcupineManager.fromBuiltInKeywords/fromKeywordPaths make real platform
// channel calls to the native Porcupine SDK, so start() itself can't be
// exercised in a widget-free unit test. What's covered here: the interface
// surface before any native call happens, the no-op safety of stop()/
// dispose() on a never-started engine (part of the mutual-exclusivity
// contract other code relies on), and the built-in-keyword matching rules,
// which are pure Dart and the part most likely to have an off-by-one in the
// name normalization.
void main() {
  test('exposes id/label and starts not running', () {
    final engine = PorcupineWakeWordEngine(accessKey: 'test-access-key');
    expect(engine.id, 'porcupine');
    expect(engine.label, isNotEmpty);
    expect(engine.running, isFalse);
  });

  test('stop() before start() is a harmless no-op', () async {
    final engine = PorcupineWakeWordEngine(accessKey: 'test-access-key');
    await expectLater(engine.stop(), completes);
    expect(engine.running, isFalse);
  });

  test('dispose() before start() is a harmless no-op', () async {
    final engine = PorcupineWakeWordEngine(accessKey: 'test-access-key');
    await expectLater(engine.dispose(), completes);
  });

  group('matchBuiltInKeyword', () {
    test('matches built-in keyword names case/spacing-insensitively', () {
      expect(
        PorcupineWakeWordEngine.matchBuiltInKeyword('jarvis'),
        BuiltInKeyword.JARVIS,
      );
      expect(
        PorcupineWakeWordEngine.matchBuiltInKeyword('Hey Google'),
        BuiltInKeyword.HEY_GOOGLE,
      );
      expect(
        PorcupineWakeWordEngine.matchBuiltInKeyword('HEY-GOOGLE'),
        BuiltInKeyword.HEY_GOOGLE,
      );
      expect(
        PorcupineWakeWordEngine.matchBuiltInKeyword('  computer  '),
        BuiltInKeyword.COMPUTER,
      );
    });

    test('returns null for a custom .ppn file path', () {
      expect(
        PorcupineWakeWordEngine.matchBuiltInKeyword(
          '/data/user/0/com.dhivalabs.home_deck/files/custom.ppn',
        ),
        isNull,
      );
    });
  });
}
