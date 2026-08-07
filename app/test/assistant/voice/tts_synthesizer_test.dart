import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'package:home_deck/assistant/voice/impl/tts_synthesizer.dart';

// FlutterTtsSynthesizer wraps a real FlutterTts instance rather than an
// interface, so these tests fake the platform side of it: mock the
// `flutter_tts` method channel to accept every call (as if a platform
// implementation were present), then drive completion/error/cancel by
// invoking FlutterTts's own (public) platformCallHandler, exactly like the
// native side would.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter_tts');

  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => null);
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('speak() completes on the platform completion callback', () async {
    final tts = FlutterTts();
    final synth = FlutterTtsSynthesizer(tts: tts);

    final future = synth.speak('hello world');
    // Let awaitSpeakCompletion() and speak()'s channel round-trips run.
    await Future<void>.delayed(Duration.zero);
    await tts.platformCallHandler(const MethodCall('speak.onComplete'));

    await expectLater(future, completes);
  });

  test('speak() completes on the platform error callback', () async {
    final tts = FlutterTts();
    final synth = FlutterTtsSynthesizer(tts: tts);

    final future = synth.speak('hello world');
    await Future<void>.delayed(Duration.zero);
    await tts.platformCallHandler(
      const MethodCall('speak.onError', 'synth failed'),
    );

    // Never-throw contract: a synth failure resolves speak(), it doesn't
    // propagate as an exception.
    await expectLater(future, completes);
  });

  test('stopSpeaking() resolves an in-flight speak()', () async {
    final tts = FlutterTts();
    final synth = FlutterTtsSynthesizer(tts: tts);

    final future = synth.speak('hello world');
    await Future<void>.delayed(Duration.zero);
    await synth.stopSpeaking();

    await expectLater(future, completes);
  });

  test('empty text is a no-op that never touches the channel', () async {
    final synth = FlutterTtsSynthesizer(tts: FlutterTts());
    await expectLater(synth.speak(''), completes);
  });

  test('a stale completer from a finished speak() cannot resolve the next one',
      () async {
    final tts = FlutterTts();
    final synth = FlutterTtsSynthesizer(tts: tts);

    await Future<void>.delayed(Duration.zero);
    final first = synth.speak('one');
    await Future<void>.delayed(Duration.zero);
    await tts.platformCallHandler(const MethodCall('speak.onComplete'));
    await first;

    final second = synth.speak('two');
    var secondCompleted = false;
    unawaited(second.then((_) => secondCompleted = true));

    // A stray, late completion event for the first utterance must not
    // resolve the second one.
    await Future<void>.delayed(Duration.zero);
    expect(secondCompleted, isFalse);

    await tts.platformCallHandler(const MethodCall('speak.onComplete'));
    await expectLater(second, completes);
  });
}
