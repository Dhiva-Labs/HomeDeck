import 'package:flutter/foundation.dart';

import '../intent.dart';

/// What the parser is allowed to know about the user's home.
///
/// Passing the live device and room names in lets the grammar anchor on real
/// vocabulary ("desk lamp" is a device here, not a stray noun) without the
/// NLU holding a reference to the registry.
@immutable
class NluContext {
  const NluContext({
    this.deviceNames = const [],
    this.roomNames = const [],
    this.sceneNames = const [],
  });

  final List<String> deviceNames;
  final List<String> roomNames;
  final List<String> sceneNames;
}

/// Turns an utterance into an [Intent].
///
/// Implementations must be pure and synchronous-ish: no network, no disk. The
/// shipped implementation ([RulesNlu]) is a deterministic grammar, which is
/// what keeps the assistant working with the network down.
abstract class NluEngine {
  /// Parse [utterance]. Returns an [Intent] with `IntentType.unknown` rather
  /// than null when nothing matched, so callers always get an utterance back
  /// for the transcript.
  Intent parse(String utterance, NluContext context);
}
