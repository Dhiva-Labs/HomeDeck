import '../models/device.dart';
import '../services/connectors_service.dart';
import 'device_resolver.dart';
import 'intent.dart';

/// The outcome of executing (or failing to execute) an intent, phrased for
/// both the transcript UI and text-to-speech.
class ExecutionResult {
  const ExecutionResult({
    required this.ok,
    required this.spoken,
    this.devices = const [],
    this.needsDisambiguation = false,
    this.isQueryAnswer = false,
  });

  final bool ok;

  /// What the assistant says back. Kept short — TTS reads every word.
  final String spoken;

  final List<Device> devices;

  /// True when [spoken] is a question and the next utterance should be parsed
  /// as the answer ("which one?" -> "the desk lamp").
  final bool needsDisambiguation;

  /// True when [spoken] is the answer to a question ("is the lamp on?") —
  /// always worth voicing, unlike command confirmations which stay silent.
  final bool isQueryAnswer;
}

/// Turns a parsed [Intent] into [DeviceAction]s on real devices.
///
/// Only emits action names the connectors already understand: turn_on,
/// turn_off, toggle, set_brightness (0-100), set_temperature, wake. Anything
/// device-specific stays the connector's problem.
class IntentExecutor {
  IntentExecutor(this.connectors, this.resolver);

  final ConnectorsService connectors;
  final DeviceResolver resolver;

  Future<ExecutionResult> execute(Intent intent) async {
    if (intent.type == IntentType.unknown) {
      return const ExecutionResult(
        ok: false,
        spoken: "Sorry, I didn't understand that.",
      );
    }
    if (intent.type == IntentType.stop) {
      return const ExecutionResult(ok: true, spoken: 'Okay.');
    }

    final resolution = resolver.resolve(intent);
    switch (resolution.status) {
      case ResolutionStatus.none:
        return ExecutionResult(
          ok: false,
          spoken: _noMatchReply(intent),
        );
      case ResolutionStatus.ambiguous:
        return ExecutionResult(
          ok: false,
          spoken: _whichOne(resolution.devices),
          devices: resolution.devices,
          needsDisambiguation: true,
        );
      case ResolutionStatus.matched:
        break;
    }

    final devices = resolution.devices;

    if (intent.type == IntentType.query) {
      return ExecutionResult(
        ok: true,
        spoken: _describe(devices),
        devices: devices,
        isQueryAnswer: true,
      );
    }
    if (intent.type == IntentType.showCamera) {
      // The UI layer watches for this and opens the camera view itself.
      return ExecutionResult(
        ok: true,
        spoken: 'Showing ${devices.first.name}.',
        devices: devices,
      );
    }

    final failures = <String>[];
    for (final device in devices) {
      final action = _actionFor(intent, device);
      if (action == null) continue;
      try {
        await connectors.invoke(device, action);
      } catch (e) {
        failures.add(device.name);
      }
    }

    if (failures.length == devices.length && devices.isNotEmpty) {
      return ExecutionResult(
        ok: false,
        spoken: "I couldn't reach ${_nameList(failures)}.",
        devices: devices,
      );
    }
    return ExecutionResult(
      ok: true,
      spoken: _confirmation(intent, devices, failures),
      devices: devices,
    );
  }

  // ---- Intent -> DeviceAction -------------------------------------------------

  DeviceAction? _actionFor(Intent intent, Device device) {
    switch (intent.type) {
      case IntentType.turnOn:
        return const DeviceAction('turn_on');
      case IntentType.turnOff:
        return const DeviceAction('turn_off');
      case IntentType.toggle:
      case IntentType.activateScene:
        return const DeviceAction('toggle'); // HA maps scene toggle -> turn_on
      case IntentType.setBrightness:
        final value = intent.args['value'];
        if (value == null) return const DeviceAction('turn_on');
        return DeviceAction('set_brightness', {'value': value});
      case IntentType.changeBrightness:
        final current = (device.state['brightness'] as num?)?.toInt() ?? 50;
        final delta = (intent.args['delta'] as num?)?.toInt() ?? 25;
        return DeviceAction(
            'set_brightness', {'value': (current + delta).clamp(0, 100)});
      case IntentType.setTemperature:
        final value = intent.args['value'];
        if (value == null) return null;
        return DeviceAction('set_temperature', {'value': value});
      case IntentType.changeTemperature:
        final current =
            (device.state['targetTemp'] as num?) ?? (device.state['value'] as num?);
        final delta = (intent.args['delta'] as num?) ?? 1;
        if (current == null) return null;
        return DeviceAction('set_temperature', {'value': current + delta});
      case IntentType.wakeComputer:
        return const DeviceAction('wake');
      case IntentType.query:
      case IntentType.showCamera:
      case IntentType.stop:
      case IntentType.unknown:
        return null;
    }
  }

  // ---- Replies ---------------------------------------------------------------

  String _confirmation(
      Intent intent, List<Device> devices, List<String> failed) {
    final acted = devices.where((d) => !failed.contains(d.name)).toList();
    final what = acted.length == 1
        ? acted.first.name
        : '${acted.length} devices';
    final base = switch (intent.type) {
      IntentType.turnOn => 'Turned on $what.',
      IntentType.turnOff => 'Turned off $what.',
      IntentType.toggle => 'Toggled $what.',
      IntentType.activateScene => 'Activated ${acted.first.name}.',
      IntentType.setBrightness =>
        'Set $what to ${intent.args['value']} percent.',
      IntentType.changeBrightness => 'Adjusted $what.',
      IntentType.setTemperature =>
        'Set $what to ${intent.args['value']} degrees.',
      IntentType.changeTemperature => 'Adjusted $what.',
      IntentType.wakeComputer => 'Waking $what.',
      _ => 'Done.',
    };
    if (failed.isEmpty) return base;
    return "$base Couldn't reach ${_nameList(failed)}.";
  }

  String _describe(List<Device> devices) {
    if (devices.length == 1) {
      final d = devices.first;
      if (d.state.containsKey('value')) {
        final unit = (d.attrs['unit'] as String?) ?? '';
        return '${d.name} is ${d.state['value']}$unit.';
      }
      if (d.state.containsKey('on')) {
        return '${d.name} is ${d.isOn ? 'on' : 'off'}.';
      }
      return '${d.name} is ${d.online ? 'online' : 'offline'}.';
    }
    final on = devices.where((d) => d.isOn).length;
    return '$on of ${devices.length} are on.';
  }

  String _noMatchReply(Intent intent) {
    final t = intent.target;
    if (t.isEmpty) {
      return switch (intent.type) {
        IntentType.turnOn => 'Turn on what?',
        IntentType.turnOff => 'Turn off what?',
        _ => "Sorry, I'm not sure what you meant.",
      };
    }
    final named = t.phrase ?? t.kind?.name ?? t.room ?? 'that';
    return "I couldn't find $named.";
  }

  String _whichOne(List<Device> devices) {
    final names = devices.take(3).map((d) => d.name).toList();
    final list = _nameList(names);
    return devices.length > 3
        ? 'Which one? $list, or others?'
        : 'Which one? $list?';
  }

  String _nameList(List<String> names) {
    if (names.isEmpty) return 'them';
    if (names.length == 1) return names.first;
    return '${names.sublist(0, names.length - 1).join(', ')} or ${names.last}';
  }
}
