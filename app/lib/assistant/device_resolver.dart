import '../models/device.dart';
import '../services/device_registry.dart';
import 'intent.dart';

/// Why a resolution produced what it did — drives the assistant's reply.
enum ResolutionStatus {
  /// Exactly the devices to act on.
  matched,

  /// Several plausible devices and the user didn't say "all" — the assistant
  /// should ask which one.
  ambiguous,

  /// Nothing in the registry fits.
  none,
}

class Resolution {
  const Resolution(this.status, this.devices);

  const Resolution.none()
      : status = ResolutionStatus.none,
        devices = const [];

  final ResolutionStatus status;
  final List<Device> devices;
}

/// Maps a [TargetSpec] onto real devices from the [DeviceRegistry].
///
/// Matching is defensive about speech-to-text: names are compared on
/// normalized tokens with a fuzzy fallback, because "desk lamp" arrives as
/// "does lamp" often enough to matter.
class DeviceResolver {
  DeviceResolver(this.registry);

  final DeviceRegistry registry;

  Resolution resolve(Intent intent) {
    final target = intent.target;
    var candidates = registry.devices.where((d) => d.online).toList();

    // Scenes are a kind of their own; a scene intent narrows to them first.
    if (intent.type == IntentType.activateScene) {
      candidates =
          candidates.where((d) => d.kind == DeviceKind.scene).toList();
    } else if (intent.type == IntentType.showCamera) {
      candidates =
          candidates.where((d) => d.kind == DeviceKind.camera).toList();
    } else if (intent.type == IntentType.wakeComputer) {
      candidates = candidates
          .where((d) => d.can(DeviceCapability.wake))
          .toList();
    }

    if (target.room != null) {
      final inRoom =
          candidates.where((d) => d.room == target.room).toList();
      // Only narrow when the room actually contains something; a mis-heard
      // room should not empty the pool before name matching gets a chance.
      if (inRoom.isNotEmpty) candidates = inRoom;
    }

    if (target.kind != null) {
      final ofKind =
          candidates.where((d) => d.kind == target.kind).toList();
      if (ofKind.isNotEmpty) candidates = ofKind;
    }

    // A name phrase narrows further — best score wins, ties stay ambiguous.
    if (target.phrase != null && target.phrase!.isNotEmpty) {
      final scored = candidates
          .map((d) => (device: d, score: _score(target.phrase!, d.name)))
          .where((e) => e.score > 0.45)
          .toList()
        ..sort((a, b) => b.score.compareTo(a.score));

      if (scored.isEmpty) {
        // The user named something specific and nothing fits. Failing here
        // beats "helpfully" acting on every device of that kind — a named
        // target must never degrade into a group action.
        return const Resolution.none();
      }
      final best = scored.first.score;
      candidates = scored
          .where((e) => e.score >= best - 0.1)
          .map((e) => e.device)
          .toList();
    }

    if (candidates.isEmpty) return const Resolution.none();
    if (candidates.length == 1 || target.all || _isGroupIntent(intent)) {
      return Resolution(ResolutionStatus.matched, candidates);
    }
    // Several matches of the same kind: act on all of them instead of
    // asking. "Turn on the light" with three lights turns on three lights —
    // the assistant should do the work, not run a quiz. Mixed kinds (a name
    // matching both a lamp and a heater) still ask, because guessing there
    // means actuating the wrong class of hardware.
    if (_actsOnGroups(intent.type) &&
        candidates.every((d) => d.kind == candidates.first.kind)) {
      return Resolution(ResolutionStatus.matched, candidates);
    }
    return Resolution(ResolutionStatus.ambiguous, candidates);
  }

  /// Intent types where acting on every same-kind match is what the user
  /// meant. Queries answer over the set anyway; camera views can only show
  /// one, so they still disambiguate.
  bool _actsOnGroups(IntentType type) => switch (type) {
        IntentType.turnOn ||
        IntentType.turnOff ||
        IntentType.toggle ||
        IntentType.setBrightness ||
        IntentType.changeBrightness ||
        IntentType.setTemperature ||
        IntentType.changeTemperature =>
          true,
        _ => false,
      };

  /// Acting on many devices at once is expected for on/off scoped to a room
  /// ("turn off the bedroom"), even without an explicit "all". A bare kind
  /// stays ambiguous — plurality is the grammar's call via `target.all`.
  bool _isGroupIntent(Intent intent) {
    final onOff = intent.type == IntentType.turnOn ||
        intent.type == IntentType.turnOff;
    return onOff && intent.target.phrase == null && intent.target.room != null;
  }

  // ---- Fuzzy name matching ---------------------------------------------------

  double _score(String query, String name) {
    final q = _tokens(query);
    final n = _tokens(name);
    if (q.isEmpty || n.isEmpty) return 0;

    // Exact and containment checks first — cheap and common.
    final qJoined = q.join(' ');
    final nJoined = n.join(' ');
    if (qJoined == nJoined) return 1.0;
    if (nJoined.contains(qJoined) || qJoined.contains(nJoined)) return 0.9;

    // Token overlap with per-token fuzz, scored against the query length so
    // saying a subset of a long name ("lamp" for "IKEA desk lamp") works.
    var hits = 0.0;
    for (final qt in q) {
      var best = 0.0;
      for (final nt in n) {
        final sim = _tokenSimilarity(qt, nt);
        if (sim > best) best = sim;
      }
      hits += best;
    }
    return hits / q.length;
  }

  double _tokenSimilarity(String a, String b) {
    if (a == b) return 1.0;
    if (a.length >= 4 && b.length >= 4) {
      if (b.startsWith(a) || a.startsWith(b)) return 0.85;
      final distance = _levenshtein(a, b);
      final maxLen = a.length > b.length ? a.length : b.length;
      final sim = 1 - distance / maxLen;
      if (sim >= 0.7) return sim; // "does"/"desk" = 0.5, rejected; "lite"/"light" passes
    }
    return 0.0;
  }

  List<String> _tokens(String text) => text
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9\s]'), ' ')
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty && !_stopTokens.contains(t))
      .toList();

  static const _stopTokens = {'the', 'a', 'an', 'my'};

  int _levenshtein(String a, String b) {
    final m = a.length, n = b.length;
    var prev = List<int>.generate(n + 1, (j) => j);
    var curr = List<int>.filled(n + 1, 0);
    for (var i = 1; i <= m; i++) {
      curr[0] = i;
      for (var j = 1; j <= n; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        curr[j] = [
          prev[j] + 1,
          curr[j - 1] + 1,
          prev[j - 1] + cost,
        ].reduce((x, y) => x < y ? x : y);
      }
      final tmp = prev;
      prev = curr;
      curr = tmp;
    }
    return prev[n];
  }
}
