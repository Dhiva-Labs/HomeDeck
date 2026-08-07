import '../../models/device.dart';
import '../intent.dart';
import 'nlu_engine.dart';

/// A deterministic, fully offline command grammar.
///
/// Parsing runs in four passes: normalize the text, pull out numeric
/// arguments, identify the verb, then read whatever is left as the target.
/// Nothing here touches the network, so the assistant keeps working when the
/// internet (or Home Assistant) is down — the lights are on the same LAN
/// either way.
class RulesNlu implements NluEngine {
  const RulesNlu();

  @override
  Intent parse(String utterance, NluContext context) {
    final normalized = _normalize(utterance);
    if (normalized.isEmpty) return Intent.unknown(utterance);

    if (_stopRe.hasMatch(normalized)) {
      return Intent(
        type: IntentType.stop,
        target: const TargetSpec(),
        utterance: normalized,
      );
    }

    var text = normalized;
    final args = <String, dynamic>{};

    // ---- Pass 1: numeric arguments ------------------------------------------
    // Pulled out first because the numbers would otherwise pollute the target
    // phrase ("set the lamp to 40 percent" must not look for a device called
    // "lamp to 40 percent").
    final relative = _relativeRe.hasMatch(text);

    final percentMatch = _percentRe.firstMatch(text);
    if (percentMatch != null) {
      args['percent'] = int.parse(percentMatch.group(1)!).clamp(0, 100);
      text = text.replaceRange(percentMatch.start, percentMatch.end, ' ');
    }

    final degreeMatch = _degreeRe.firstMatch(text);
    if (degreeMatch != null) {
      args['degrees'] = double.parse(degreeMatch.group(1)!);
      text = text.replaceRange(degreeMatch.start, degreeMatch.end, ' ');
    }

    // A bare "to 21" with no unit, e.g. "set the thermostat to 21".
    if (args.isEmpty) {
      final bare = _bareNumberRe.firstMatch(text);
      if (bare != null) {
        args['number'] = double.parse(bare.group(1)!);
        text = text.replaceRange(bare.start, bare.end, ' ');
      }
    }

    // ---- Pass 2: the verb ----------------------------------------------------
    var confidence = 1.0;
    var type = IntentType.unknown;

    for (final rule in _verbRules) {
      final match = rule.pattern.firstMatch(text);
      if (match == null) continue;
      type = rule.type;
      text = text.replaceRange(match.start, match.end, ' ');
      break;
    }

    // Trailing form: "kitchen lights on", "desk lamp off".
    if (type == IntentType.unknown) {
      final trailing = _trailingStateRe.firstMatch(text);
      if (trailing != null) {
        type = trailing.group(1) == 'on' ? IntentType.turnOn : IntentType.turnOff;
        text = text.replaceRange(trailing.start, trailing.end, ' ');
        confidence = 0.8;
      }
    }

    // ---- Pass 3: reconcile verb with arguments ------------------------------
    type = _reconcile(type, args, relative);

    if (type == IntentType.setBrightness) {
      args['value'] = args['percent'] ?? args['number']?.round();
    } else if (type == IntentType.setTemperature) {
      args['value'] = args['degrees'] ?? args['number'];
    } else if (type == IntentType.changeBrightness) {
      // "dim the lights" with no number is a sensible fixed step.
      final magnitude = (args['percent'] ?? args['number']?.round() ?? 25) as int;
      args['delta'] = _isDecrease(normalized) ? -magnitude : magnitude;
    } else if (type == IntentType.changeTemperature) {
      final magnitude = (args['degrees'] ?? args['number'] ?? 1.0) as num;
      args['delta'] = _isDecrease(normalized) ? -magnitude : magnitude;
    }

    if (type == IntentType.unknown) return Intent.unknown(normalized);

    // ---- Pass 4: the target --------------------------------------------------
    final target = _extractTarget(text, context);
    if (target.isEmpty && _needsTarget(type)) {
      // A verb with nothing to act on: still report it so the UI can ask
      // "turn off what?" instead of a flat "I didn't understand".
      confidence = 0.4;
    }

    return Intent(
      type: type,
      target: target,
      args: args,
      confidence: confidence,
      utterance: normalized,
    );
  }

  // ---- Target extraction -----------------------------------------------------

  TargetSpec _extractTarget(String text, NluContext context) {
    var rest = _clean(text);

    final all = _allRe.hasMatch(rest);
    rest = rest.replaceAll(_allRe, ' ');
    rest = _clean(rest.replaceAll(_fillerRe, ' '));

    // Longest room name first, so "living room" wins over a room called "room".
    String? room;
    var residual = rest;
    final rooms = [...context.roomNames]
      ..sort((a, b) => b.length.compareTo(a.length));
    for (final candidate in rooms) {
      final needle = candidate.toLowerCase();
      if (needle.isEmpty) continue;
      if (_containsWord(residual, needle)) {
        room = candidate;
        residual = _removeWord(residual, needle);
        break;
      }
    }

    // Device kind: check the plural/longer synonyms first ("light switch"
    // should not match as a bare switch).
    DeviceKind? kind;
    var kindWasPlural = false;
    for (final entry in _kindSynonyms.entries) {
      if (_containsWord(residual, entry.key)) {
        kind = entry.value;
        kindWasPlural = _pluralKinds.contains(entry.key);
        residual = _removeWord(residual, entry.key);
        break;
      }
    }
    residual = _clean(residual);

    // When room + kind explain the whole noun phrase ("kitchen lights"),
    // drop the phrase: name matching on "lights" would wrongly narrow to a
    // single device whose name happens to contain the word. Any residue
    // ("desk lamp" -> "desk") keeps the full phrase for fuzzy name matching.
    return TargetSpec(
      phrase: residual.isEmpty ? null : rest,
      room: room,
      kind: kind,
      // "turn off the lights" (plural) with no specific device reads as
      // "all of them"; the singular "turn on the light" does not — with
      // several lights that should come back as a "which one?" question.
      all: all || (kind != null && kindWasPlural && residual.isEmpty),
    );
  }

  /// Remove one whole-word occurrence of [needle] from [haystack].
  String _removeWord(String haystack, String needle) => _clean(haystack.replaceFirst(
      RegExp('(?:^| )${RegExp.escape(needle)}(?=\$| )'), ' '));

  // ---- Helpers ---------------------------------------------------------------

  IntentType _reconcile(
      IntentType type, Map<String, dynamic> args, bool relative) {
    final hasPercent = args.containsKey('percent');
    final hasDegrees = args.containsKey('degrees');
    final hasNumber = args.containsKey('number');

    switch (type) {
      // "set X to 50%" parses its verb as a generic set.
      case IntentType.setBrightness when !hasPercent && hasDegrees:
        return IntentType.setTemperature;
      case IntentType.setBrightness when !hasPercent && !hasNumber:
        // "set the lamp" with no value is meaningless; treat as turn on.
        return IntentType.turnOn;
      case IntentType.changeBrightness when hasPercent && !relative:
        return IntentType.setBrightness;
      case IntentType.turnOn when hasPercent:
        return IntentType.setBrightness;
      case IntentType.turnOn when hasDegrees:
        return IntentType.setTemperature;
      default:
        return type;
    }
  }

  bool _needsTarget(IntentType type) =>
      type != IntentType.stop && type != IntentType.unknown;

  bool _isDecrease(String text) => _decreaseRe.hasMatch(text);

  /// Word-boundary containment, so "on" does not match inside "kitchen".
  bool _containsWord(String haystack, String needle) =>
      RegExp('(?:^| )${RegExp.escape(needle)}(?:\$| )').hasMatch(haystack);

  String _clean(String text) => text.replaceAll(_spaceRe, ' ').trim();

  String _normalize(String raw) {
    var text = raw.toLowerCase();
    text = text.replaceAll(_punctuationRe, ' ');
    text = _expandNumberWords(text);
    text = text.replaceAll(_politenessRe, ' ');
    return _clean(text);
  }

  /// "twenty five" -> "25", "fifty" -> "50". Enough for percentages and
  /// thermostat setpoints, which is all the grammar takes numbers for.
  String _expandNumberWords(String text) {
    final words = text.split(' ');
    final out = <String>[];
    for (var i = 0; i < words.length; i++) {
      final value = _numberWords[words[i]];
      if (value == null) {
        out.add(words[i]);
        continue;
      }
      // Compound tens: "twenty five" -> 25.
      if (value >= 20 &&
          value % 10 == 0 &&
          i + 1 < words.length &&
          (_numberWords[words[i + 1]] ?? 10) < 10) {
        out.add('${value + _numberWords[words[i + 1]]!}');
        i++;
      } else {
        out.add('$value');
      }
    }
    return out.join(' ');
  }
}

// ---- Patterns ----------------------------------------------------------------

class _VerbRule {
  _VerbRule(this.pattern, this.type);
  final RegExp pattern;
  final IntentType type;
}

/// Ordered: the first match wins, so longer/more specific phrasings come first.
final _verbRules = <_VerbRule>[
  _VerbRule(RegExp(r'\b(?:turn|switch|power|shut)\s+(?:it\s+)?off\b'),
      IntentType.turnOff),
  _VerbRule(RegExp(r'\b(?:turn|switch|power|put)\s+(?:it\s+)?on\b'),
      IntentType.turnOn),
  _VerbRule(RegExp(r'\bshut\s+down\b'), IntentType.turnOff),
  _VerbRule(RegExp(r'\bkill\b'), IntentType.turnOff),
  _VerbRule(RegExp(r'\btoggle\b|\bflip\b'), IntentType.toggle),
  _VerbRule(RegExp(r'\b(?:dim|darken)\b'), IntentType.changeBrightness),
  _VerbRule(RegExp(r'\b(?:brighten)\b'), IntentType.changeBrightness),
  _VerbRule(
      RegExp(r'\b(?:make|turn)\s+(?:it\s+)?(?:brighter|darker)\b'),
      IntentType.changeBrightness),
  _VerbRule(RegExp(r'\b(?:warmer|cooler|colder|hotter)\b'),
      IntentType.changeTemperature),
  _VerbRule(RegExp(r'\bset\b|\bchange\b|\badjust\b'), IntentType.setBrightness),
  _VerbRule(RegExp(r'\b(?:activate|run|start|play)\s+(?:the\s+)?scene\b'),
      IntentType.activateScene),
  _VerbRule(RegExp(r'\b(?:activate|trigger)\b'), IntentType.activateScene),
  _VerbRule(RegExp(r'\bshow\s+(?:me\s+)?\b'), IntentType.showCamera),
  _VerbRule(RegExp(r'\bwake\s+(?:up\s+)?\b'), IntentType.wakeComputer),
  _VerbRule(
      RegExp(r"\b(?:is|are|what(?:'|)s|what\s+is|how(?:'|)s|status\s+of)\b"),
      IntentType.query),
];

final _stopRe =
    RegExp(r'^(?:stop|cancel|never\s*mind|forget\s+it|quit|shut\s+up)\b');

final _percentRe = RegExp(r'\b(\d{1,3})\s*(?:percent|%)');
final _degreeRe = RegExp(r'\b(\d{1,3}(?:\.\d+)?)\s*(?:degrees?|deg|°|c\b|f\b)');
final _bareNumberRe = RegExp(r'\bto\s+(\d{1,3}(?:\.\d+)?)\b');

final _relativeRe = RegExp(r'\bby\b|\bmore\b|\bless\b|\ba\s+bit\b');
final _decreaseRe = RegExp(
    r'\b(?:dim|darken|darker|lower|down|cooler|colder|reduce|decrease|less)\b');

final _trailingStateRe = RegExp(r'\s+(on|off)\s*$');
final _allRe = RegExp(r'\b(?:all|every|everything|whole)\b');

final _punctuationRe = RegExp(r"[^\w\s%°']");
final _spaceRe = RegExp(r'\s+');
final _politenessRe = RegExp(
    r'\b(?:please|could\s+you|can\s+you|would\s+you|i\s+want\s+to|i\s+need\s+to|for\s+me)\b');

/// Articles, prepositions and leftovers that are never part of a device name.
final _fillerRe = RegExp(
    r'\b(?:the|a|an|my|our|to|in|at|of|is|are|it|that|this|and|then|by|bit|please)\b');

/// Kind words that imply "all of them" when no specific device is named.
const _pluralKinds = {
  'lights',
  'lamps',
  'bulbs',
  'outlets',
  'plugs',
  'sockets',
  'switches',
  'cameras',
  'speakers',
};

/// Longest and most specific first — the map is iterated in insertion order.
const _kindSynonyms = <String, DeviceKind>{
  'light switch': DeviceKind.switch_,
  'lights': DeviceKind.light,
  'light': DeviceKind.light,
  'lamps': DeviceKind.light,
  'lamp': DeviceKind.light,
  'bulbs': DeviceKind.light,
  'bulb': DeviceKind.light,
  'outlets': DeviceKind.outlet,
  'outlet': DeviceKind.outlet,
  'plugs': DeviceKind.outlet,
  'plug': DeviceKind.outlet,
  'sockets': DeviceKind.outlet,
  'socket': DeviceKind.outlet,
  'switches': DeviceKind.switch_,
  'switch': DeviceKind.switch_,
  'cameras': DeviceKind.camera,
  'camera': DeviceKind.camera,
  'thermostat': DeviceKind.climate,
  'heating': DeviceKind.climate,
  'heater': DeviceKind.climate,
  'ac': DeviceKind.climate,
  'speakers': DeviceKind.speaker,
  'speaker': DeviceKind.speaker,
  'tv': DeviceKind.tv,
  'television': DeviceKind.tv,
  'computer': DeviceKind.computer,
  'pc': DeviceKind.computer,
  'desktop': DeviceKind.computer,
  'printer': DeviceKind.printer,
  'scene': DeviceKind.scene,
  'sensor': DeviceKind.sensor,
};

const _numberWords = <String, int>{
  'zero': 0,
  'one': 1,
  'two': 2,
  'three': 3,
  'four': 4,
  'five': 5,
  'six': 6,
  'seven': 7,
  'eight': 8,
  'nine': 9,
  'ten': 10,
  'eleven': 11,
  'twelve': 12,
  'thirteen': 13,
  'fourteen': 14,
  'fifteen': 15,
  'sixteen': 16,
  'seventeen': 17,
  'eighteen': 18,
  'nineteen': 19,
  'twenty': 20,
  'thirty': 30,
  'forty': 40,
  'fifty': 50,
  'sixty': 60,
  'seventy': 70,
  'eighty': 80,
  'ninety': 90,
  'hundred': 100,
};
