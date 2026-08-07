import 'package:flutter/material.dart';

/// Which wake-word engine the user picked. Mirrors the two implementations
/// of `WakeWordEngine` in `lib/assistant/voice/voice_interfaces.dart`
/// ("porcupine" / "openwakeword") without importing that file — this screen
/// has no dependency on the assistant package, only on this value type.
enum WakeEngineChoice { porcupine, openEngine }

/// Mic permission state for the status row. Deliberately not
/// `permission_handler`'s `PermissionStatus` — this file has no plugin
/// dependency, so the integrator maps whatever they get back onto this.
enum MicPermissionStatus { granted, denied, notRequested }

/// Everything this screen renders, and nothing it doesn't: every field here
/// is a plain value with no dependency on `SettingsStore` or any storage
/// key. The integrator owns persistence — read the current values into one
/// of these, pass it down, and write back through [onChanged].
@immutable
class VoiceSettingsData {
  const VoiceSettingsData({
    required this.assistantEnabled,
    required this.micPermission,
    required this.wakeEngine,
    required this.wakeWord,
    required this.picovoiceAccessKey,
    required this.sensitivity,
    required this.ttsEnabled,
    required this.ttsVolume,
  });

  /// Master on/off switch for the assistant (wake word + tap-to-talk).
  final bool assistantEnabled;

  final MicPermissionStatus micPermission;

  final WakeEngineChoice wakeEngine;

  /// A bundled preset name, a typed keyword (open engine), or a file path
  /// to an imported model (`.ppn` for Porcupine) — whatever the integrator
  /// puts here is shown verbatim in the text field.
  final String wakeWord;

  /// Picovoice Console AccessKey. Only relevant when [wakeEngine] is
  /// [WakeEngineChoice.porcupine]; ignored (and hidden) otherwise.
  final String picovoiceAccessKey;

  /// 0-1, engine-normalized wake-word sensitivity.
  final double sensitivity;

  final bool ttsEnabled;

  /// 0-1 TTS playback volume.
  final double ttsVolume;

  VoiceSettingsData copyWith({
    bool? assistantEnabled,
    MicPermissionStatus? micPermission,
    WakeEngineChoice? wakeEngine,
    String? wakeWord,
    String? picovoiceAccessKey,
    double? sensitivity,
    bool? ttsEnabled,
    double? ttsVolume,
  }) {
    return VoiceSettingsData(
      assistantEnabled: assistantEnabled ?? this.assistantEnabled,
      micPermission: micPermission ?? this.micPermission,
      wakeEngine: wakeEngine ?? this.wakeEngine,
      wakeWord: wakeWord ?? this.wakeWord,
      picovoiceAccessKey: picovoiceAccessKey ?? this.picovoiceAccessKey,
      sensitivity: sensitivity ?? this.sensitivity,
      ttsEnabled: ttsEnabled ?? this.ttsEnabled,
      ttsVolume: ttsVolume ?? this.ttsVolume,
    );
  }
}

/// Pure UI over [VoiceSettingsData]. Holds no persistent state of its own —
/// every control reads from [data] and reports changes through [onChanged],
/// so the integrator (whoever wires this to `SettingsStore` and the real
/// `WakeWordEngine`s) owns the single source of truth.
///
/// Text fields keep small local [TextEditingController]s purely so typing
/// doesn't fight the cursor on every rebuild; their text is kept in sync
/// with [data] and every edit is immediately echoed upward via [onChanged].
class VoiceSettingsScreen extends StatefulWidget {
  const VoiceSettingsScreen({
    super.key,
    required this.data,
    required this.onChanged,
    required this.onRequestMicPermission,
  });

  final VoiceSettingsData data;
  final ValueChanged<VoiceSettingsData> onChanged;

  /// Called when the user taps "Request" on the mic permission row. The
  /// integrator performs the actual platform permission request and feeds
  /// the result back in through a new [data] with an updated
  /// [VoiceSettingsData.micPermission].
  final VoidCallback onRequestMicPermission;

  @override
  State<VoiceSettingsScreen> createState() => _VoiceSettingsScreenState();
}

class _VoiceSettingsScreenState extends State<VoiceSettingsScreen> {
  late final _wakeWordController = TextEditingController(text: widget.data.wakeWord);
  late final _accessKeyController =
      TextEditingController(text: widget.data.picovoiceAccessKey);

  @override
  void didUpdateWidget(covariant VoiceSettingsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.data.wakeWord != _wakeWordController.text) {
      _wakeWordController.text = widget.data.wakeWord;
    }
    if (widget.data.picovoiceAccessKey != _accessKeyController.text) {
      _accessKeyController.text = widget.data.picovoiceAccessKey;
    }
  }

  @override
  void dispose() {
    _wakeWordController.dispose();
    _accessKeyController.dispose();
    super.dispose();
  }

  void _update(VoiceSettingsData Function(VoiceSettingsData) f) =>
      widget.onChanged(f(widget.data));

  @override
  Widget build(BuildContext context) {
    final data = widget.data;
    final isPorcupine = data.wakeEngine == WakeEngineChoice.porcupine;

    return Scaffold(
      appBar: AppBar(title: const Text('Voice assistant')),
      body: ListView(
        children: [
          const _SectionHeader('Assistant'),
          SwitchListTile(
            title: const Text('Voice assistant'),
            subtitle: const Text('Wake word listening and tap-to-talk'),
            value: data.assistantEnabled,
            onChanged: (v) => _update((d) => d.copyWith(assistantEnabled: v)),
          ),
          const Divider(),
          const _SectionHeader('Mic permission'),
          _MicPermissionRow(
            status: data.micPermission,
            onRequest: widget.onRequestMicPermission,
          ),
          const Divider(),
          const _SectionHeader('Wake word engine'),
          RadioGroup<WakeEngineChoice>(
            groupValue: data.wakeEngine,
            onChanged: (v) =>
                v == null ? null : _update((d) => d.copyWith(wakeEngine: v)),
            child: const Column(
              children: [
                RadioListTile<WakeEngineChoice>(
                  title: Text('Porcupine (needs free Picovoice key)'),
                  subtitle: Text(
                    'Better detection quality. Custom wake words need a '
                    'trained .ppn file, and the free tier is personal-use '
                    'with a 30-day model expiry.',
                  ),
                  value: WakeEngineChoice.porcupine,
                ),
                RadioListTile<WakeEngineChoice>(
                  title: Text('Open engine (sherpa-onnx)'),
                  subtitle: Text(
                    'Fully offline, no account or key. Wake word is a '
                    'typed keyword matched against the bundled/trained '
                    'model.',
                  ),
                  value: WakeEngineChoice.openEngine,
                ),
              ],
            ),
          ),
          if (isPorcupine)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: TextField(
                key: const Key('picovoiceAccessKeyField'),
                controller: _accessKeyController,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Picovoice AccessKey',
                  hintText: 'From console.picovoice.ai',
                  border: OutlineInputBorder(),
                ),
                onChanged: (v) =>
                    _update((d) => d.copyWith(picovoiceAccessKey: v)),
              ),
            ),
          const Divider(),
          const _SectionHeader('Wake word'),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
            child: TextField(
              key: const Key('wakeWordField'),
              controller: _wakeWordController,
              decoration: InputDecoration(
                labelText: 'Wake word',
                hintText: isPorcupine
                    ? 'Path to a .ppn model file'
                    : 'Typed keyword, e.g. "hey jarvis"',
                border: const OutlineInputBorder(),
              ),
              onChanged: (v) => _update((d) => d.copyWith(wakeWord: v)),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
            child: Text(
              isPorcupine
                  ? 'Porcupine only recognizes its bundled presets or a '
                      'phrase you trained at console.picovoice.ai — import '
                      'the resulting .ppn file path above.'
                  : 'The open engine matches this keyword directly; type '
                      'the phrase you trained (or a bundled preset like '
                      '"hey jarvis") with no file import needed.',
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.outline,
                  ),
            ),
          ),
          const Divider(),
          const _SectionHeader('Sensitivity'),
          ListTile(
            title: Slider(
              key: const Key('sensitivitySlider'),
              value: data.sensitivity.clamp(0.0, 1.0),
              onChanged: (v) => _update((d) => d.copyWith(sensitivity: v)),
            ),
            subtitle: Text(
              '${(data.sensitivity * 100).round()}% — higher catches more '
              'wakes but false-triggers more too',
            ),
          ),
          const Divider(),
          const _SectionHeader('Voice replies'),
          SwitchListTile(
            title: const Text('Speak replies'),
            subtitle: const Text('Text-to-speech confirmation after each command'),
            value: data.ttsEnabled,
            onChanged: (v) => _update((d) => d.copyWith(ttsEnabled: v)),
          ),
          if (data.ttsEnabled)
            ListTile(
              title: Slider(
                key: const Key('ttsVolumeSlider'),
                value: data.ttsVolume.clamp(0.0, 1.0),
                onChanged: (v) => _update((d) => d.copyWith(ttsVolume: v)),
              ),
              subtitle: Text('Volume ${(data.ttsVolume * 100).round()}%'),
            ),
        ],
      ),
    );
  }
}

class _MicPermissionRow extends StatelessWidget {
  const _MicPermissionRow({required this.status, required this.onRequest});

  final MicPermissionStatus status;
  final VoidCallback onRequest;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (icon, label, color) = switch (status) {
      MicPermissionStatus.granted => (
          Icons.mic_outlined,
          'Granted — audio never leaves this device',
          scheme.primary,
        ),
      MicPermissionStatus.denied => (
          Icons.mic_off_outlined,
          'Denied — voice control is unavailable until this is granted',
          scheme.error,
        ),
      MicPermissionStatus.notRequested => (
          Icons.mic_none_outlined,
          'Not requested yet',
          scheme.outline,
        ),
    };
    return ListTile(
      leading: Icon(icon, color: color),
      title: const Text('Microphone access'),
      subtitle: Text(label),
      trailing: status == MicPermissionStatus.granted
          ? null
          : FilledButton(onPressed: onRequest, child: const Text('Request')),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader(this.title);

  final String title;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
        child: Text(
          title,
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(color: Theme.of(context).colorScheme.primary),
        ),
      );
}
