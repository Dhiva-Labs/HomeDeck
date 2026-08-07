import 'package:flutter/foundation.dart';

import '../models/device.dart';

/// What the user asked for, independent of how they phrased it.
enum IntentType {
  turnOn,
  turnOff,
  toggle,
  setBrightness,
  changeBrightness, // relative: "dim the lights", "brighter"
  setTemperature,
  changeTemperature, // relative: "warmer", "two degrees cooler"
  query, // "is the garage door open", "what's the bedroom temperature"
  activateScene,
  showCamera,
  wakeComputer,
  stop, // cancel the current interaction
  unknown,
}

/// How the user pointed at the thing(s) they meant.
///
/// The grammar fills in whichever parts it found; [DeviceResolver] turns the
/// combination into a concrete device list. "turn off the kitchen lights"
/// yields `room: "kitchen", kind: light, all: true` (no phrase — the room and
/// kind explain the whole noun phrase); "turn on the desk lamp" yields
/// `phrase: "desk lamp", kind: light`.
@immutable
class TargetSpec {
  const TargetSpec({
    this.phrase,
    this.room,
    this.kind,
    this.all = false,
  });

  /// The raw noun phrase, e.g. "kitchen light", "desk lamp". Null when the
  /// user only named a room or a kind ("turn off everything upstairs").
  final String? phrase;

  /// A room name that matched the registry's known rooms.
  final String? room;

  /// A device class the user named ("lights", "plugs", "cameras").
  final DeviceKind? kind;

  /// "all" / "every" / "everything" — act on the whole matching set rather
  /// than asking the user to disambiguate.
  final bool all;

  bool get isEmpty => phrase == null && room == null && kind == null && !all;

  @override
  String toString() =>
      'TargetSpec(phrase: $phrase, room: $room, kind: ${kind?.name}, all: $all)';
}

/// A parsed command, ready for [IntentExecutor].
@immutable
class Intent {
  const Intent({
    required this.type,
    required this.target,
    this.args = const {},
    this.confidence = 1.0,
    this.utterance = '',
  });

  const Intent.unknown(this.utterance)
      : type = IntentType.unknown,
        target = const TargetSpec(),
        args = const {},
        confidence = 0.0;

  final IntentType type;
  final TargetSpec target;

  /// Extracted values: `brightness` (0-100), `delta` (signed percent or
  /// degrees), `temperature` (degrees).
  final Map<String, dynamic> args;

  /// 0-1. The rule engine reports lower confidence when it had to guess the
  /// verb or matched only a partial pattern.
  final double confidence;

  /// The normalized text this was parsed from, kept for the UI transcript.
  final String utterance;

  @override
  String toString() =>
      'Intent(${type.name}, $target, args: $args, confidence: $confidence)';
}
