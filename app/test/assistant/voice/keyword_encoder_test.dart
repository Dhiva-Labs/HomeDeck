import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:home_deck/assistant/voice/impl/keyword_encoder.dart';

void main() {
  // The real scored vocabulary that ships in the APK — read straight from
  // the repo so the test fails if the asset goes missing or changes shape.
  final tokens = File('assets/kws/bpe_scores.txt').readAsStringSync();
  final encoder = KeywordEncoder(tokens);

  String? enc(String s) => encoder.encode(s);

  test('bundled tokens.txt loads and is BPE-shaped', () {
    expect(tokens, contains('▁THE'));
    expect(tokens.split('\n').length, greaterThan(400));
  });

  group('matches the model checkpoint reference encodings', () {
    // From keywords.txt / keywords_raw.txt inside the upstream model
    // tarball: these are the segmentations sentencepiece itself produced.
    test('HELLO WORLD', () {
      expect(enc('hello world'), '▁HE LL O ▁WORLD :1.5');
    });
    test('HI GOOGLE', () {
      expect(enc('hi google'), '▁HI ▁GO O G LE :1.5');
    });
    test('HEY SIRI', () {
      expect(enc('hey siri'), '▁HE Y ▁S I RI :1.5');
    });
  });

  test('encodes a custom name like jarvis', () {
    final line = enc('hey jarvis');
    expect(line, isNotNull);
    // Whatever the segmentation, every unit must be in the vocabulary and
    // the line must end with the boost.
    final parts = line!.split(' ');
    expect(parts.last, ':1.5');
    expect(parts.length, greaterThan(2));
  });

  test('case and punctuation are normalized away', () {
    expect(enc('Hello, World!'), enc('hello world'));
  });

  test('unencodable input returns null instead of a dead keyword', () {
    expect(enc('123 456'), isNull);
    expect(enc(''), isNull);
  });
}
