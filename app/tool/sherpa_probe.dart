// Loads the native sherpa-onnx / onnxruntime libraries and runs the bundled
// wake-word model over a few seconds of synthetic audio, so a CI runner can
// show the prebuilt libraries really execute on its CPU architecture.
//
//   LD_LIBRARY_PATH=build/linux/<arch>/release/bundle/lib \
//     dart run tool/sherpa_probe.dart
//
// Exit code 0 means: the library loaded, the three ONNX models were opened and
// the streaming decoder consumed audio. It does not claim the keyword fires;
// that needs a real voice.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:home_deck/assistant/voice/impl/keyword_encoder.dart';
import 'package:sherpa_onnx/sherpa_onnx.dart';

const _sampleRate = 16000;

Never _fail(String message) {
  stderr.writeln('sherpa_probe: $message');
  exit(1);
}

void main() {
  initBindings();
  final version = getVersion();
  stdout.writeln('sherpa-onnx ${version.isEmpty ? '(unknown)' : version} '
      '(${getGitSha1()}) loaded on ${Platform.operatingSystem}');
  if (version.isEmpty) _fail('native library reported no version');

  final scores = File('assets/kws/bpe_scores.txt').readAsStringSync();
  final keywords = KeywordEncoder(scores).encode('hey jarvis');
  if (keywords == null) _fail('keyword encoder returned null');
  stdout.writeln('keywords: $keywords');

  // sherpa-onnx 1.13.4 refuses to create a spotter that has no keywords at
  // construction time, so they are handed over in keywordsBuf here as well as
  // per stream.
  final spotter = KeywordSpotter(KeywordSpotterConfig(
    model: OnlineModelConfig(
      transducer: OnlineTransducerModelConfig(
        encoder: 'assets/kws/encoder.onnx',
        decoder: 'assets/kws/decoder.onnx',
        joiner: 'assets/kws/joiner.onnx',
      ),
      tokens: 'assets/kws/tokens.txt',
      modelType: 'zipformer2',
    ),
    keywordsThreshold: 0.25,
    keywordsBuf: keywords,
    keywordsBufSize: keywords.length,
  ));
  final stream = spotter.createStream(keywords: keywords);

  // Three seconds in 100 ms chunks: a swept tone with a little noise, so the
  // encoder has non-trivial input to chew on.
  final rng = math.Random(7);
  var decodeSteps = 0;
  for (var chunk = 0; chunk < 30; chunk++) {
    final samples = Float32List(_sampleRate ~/ 10);
    for (var i = 0; i < samples.length; i++) {
      final t = (chunk * samples.length + i) / _sampleRate;
      samples[i] = 0.2 * math.sin(2 * math.pi * (200 + 300 * t) * t) +
          0.02 * (rng.nextDouble() - 0.5);
    }
    stream.acceptWaveform(samples: samples, sampleRate: _sampleRate);
    while (spotter.isReady(stream)) {
      spotter.decode(stream);
      decodeSteps++;
    }
  }
  final keyword = spotter.getResult(stream).keyword;
  stdout.writeln('decode steps: $decodeSteps, detected keyword: '
      '${keyword.isEmpty ? '(none)' : keyword}');

  stream.free();
  spotter.free();

  if (decodeSteps == 0) _fail('the decoder never ran');
  stdout.writeln('sherpa_probe: ok');
}
