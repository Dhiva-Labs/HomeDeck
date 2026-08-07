/// Turns a typed wake name into the token line sherpa-onnx's
/// `KeywordSpotter` expects.
///
/// The bundled gigaspeech KWS model works on BPE units ("▁HE", "LL", "O"…),
/// so "hey jarvis" must arrive as "▁HE Y ▁J AR V IS", not as text. This
/// reimplements sentencepiece unigram inference: Viterbi over the model's
/// own piece scores (extracted from bpe.model into bpe_scores.txt), which
/// reproduces the exact segmentation the model was trained with —
/// approximations here directly cost wake-word recall.
class KeywordEncoder {
  /// [scoresFileContent] is `piece<TAB>score` per line. A plain tokens.txt
  /// ("piece id") also works: ids then act as flat scores, degrading to
  /// longest-match behavior — better than refusing to encode.
  KeywordEncoder(String scoresFileContent) {
    for (final line in scoresFileContent.split('\n')) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length < 2) continue;
      final piece = parts[0];
      if (piece.startsWith('<')) continue; // <blk>, <unk>, <sos/eos>
      _scores[piece] = double.tryParse(parts[1]) ?? 0;
      if (piece.length > _maxLen) _maxLen = piece.length;
    }
  }

  final Map<String, double> _scores = {};
  int _maxLen = 1;

  /// Encode [phrase] as a keywords line, e.g. "▁HE Y ▁S I RI :1.5".
  ///
  /// Returns null when the phrase contains nothing encodable — the caller
  /// should refuse to start the engine and surface that, rather than listen
  /// for a keyword that can never fire.
  String? encode(String phrase, {double boost = 1.5}) {
    final words = phrase
        .toUpperCase()
        .replaceAll(RegExp(r"[^A-Z' ]"), ' ')
        .split(RegExp(r'\s+'))
        .where((w) => w.isNotEmpty);

    final out = <String>[];
    for (final word in words) {
      final segmented = _viterbi('▁$word');
      if (segmented != null) out.addAll(segmented);
    }

    if (out.isEmpty) return null;
    return '${out.join(' ')} :$boost';
  }

  /// Best-scoring segmentation of [text] into known pieces, or null if some
  /// character can't be covered by any piece.
  List<String>? _viterbi(String text) {
    final n = text.length;
    final best = List<double>.filled(n + 1, double.negativeInfinity);
    final back = List<int>.filled(n + 1, -1);
    best[0] = 0;

    for (var end = 1; end <= n; end++) {
      final from = end - _maxLen < 0 ? 0 : end - _maxLen;
      for (var start = from; start < end; start++) {
        if (best[start] == double.negativeInfinity) continue;
        final score = _scores[text.substring(start, end)];
        if (score == null) continue;
        final total = best[start] + score;
        if (total > best[end]) {
          best[end] = total;
          back[end] = start;
        }
      }
      // Unreachable position (a character no piece covers, e.g. a stray
      // apostrophe this vocab can't attach): skip it as if unseen.
      if (best[end] == double.negativeInfinity && end < n) {
        best[end] = best[end - 1];
        back[end] = -2; // marker: gap
      }
    }

    if (best[n] == double.negativeInfinity) return null;
    final pieces = <String>[];
    var i = n;
    while (i > 0) {
      final j = back[i];
      if (j == -2) {
        i -= 1;
        continue;
      }
      if (j < 0) return null;
      pieces.insert(0, text.substring(j, i));
      i = j;
    }
    return pieces.isEmpty ? null : pieces;
  }
}
