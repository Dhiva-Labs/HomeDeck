import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../assistant/assistant_service.dart';
import '../../models/device.dart';
import '../../services/settings_store.dart';
import '../../widgets/assistant/listening_indicator.dart';
import '../../widgets/device_tile.dart' show iconForKind;

/// Opens the tap-to-talk surface as a modal bottom sheet.
///
/// [AssistantService] is expected to already be provided above the caller
/// (the app-wide provider tree — see INTEGRATION_NOTES.md), so this just
/// pushes the sheet; it does not create or own the service.
Future<void> showAssistantSheet(BuildContext context) {
  final scheme = Theme.of(context).colorScheme;
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: scheme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => const AssistantSheet(),
  );
}

/// The tap-to-talk surface: mic button, live transcript, spoken reply,
/// affected-device chips, a disambiguation prompt when the assistant needs
/// one, and a text field for devices with no mic.
///
/// Purely a view over [AssistantService] via `context.watch` — every action
/// (tap the mic, submit text, tap a disambiguation chip) calls straight
/// through to the service; this widget holds no assistant state of its own
/// beyond the text field controller.
class AssistantSheet extends StatefulWidget {
  const AssistantSheet({super.key});

  @override
  State<AssistantSheet> createState() => _AssistantSheetState();
}

class _AssistantSheetState extends State<AssistantSheet> {
  final _controller = TextEditingController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return;
    context.read<AssistantService>().handleText(trimmed);
    _controller.clear();
  }

  @override
  Widget build(BuildContext context) {
    final service = context.watch<AssistantService>();
    final lowFx = context.watch<SettingsStore>().lowFx;
    final scheme = Theme.of(context).colorScheme;

    final result = service.lastResult;
    final disambiguating = result?.needsDisambiguation ?? false;
    final showTranscript =
        service.phase == AssistantPhase.listening || service.transcript.isNotEmpty;

    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.only(
          left: 20,
          right: 20,
          top: 12,
          bottom: MediaQuery.of(context).viewInsets.bottom + 20,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const _DragHandle(),
            const SizedBox(height: 16),
            Semantics(
              button: true,
              label: 'Tap to talk',
              child: InkResponse(
                key: const Key('assistantMicButton'),
                onTap: () => service.pushToTalk(),
                radius: 64,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: ListeningIndicator(phase: service.phase, lowFx: lowFx),
                ),
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _phaseLabel(service.phase),
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: scheme.outline),
            ),
            if (showTranscript) ...[
              const SizedBox(height: 16),
              _TranscriptText(
                text: service.transcript,
                live: service.phase == AssistantPhase.listening,
              ),
            ],
            if (service.reply.isNotEmpty) ...[
              const SizedBox(height: 16),
              _ReplyBanner(ok: result?.ok ?? false, reply: service.reply),
            ],
            if (disambiguating) ...[
              const SizedBox(height: 16),
              _DisambiguationChips(
                devices: result!.devices,
                onPick: (name) => _submit(name),
              ),
            ] else if (result != null && result.devices.isNotEmpty) ...[
              const SizedBox(height: 16),
              _DeviceChips(devices: result.devices),
            ],
            const SizedBox(height: 20),
            _CommandTextField(controller: _controller, onSubmit: _submit),
          ],
        ),
      ),
    );
  }

  String _phaseLabel(AssistantPhase phase) => switch (phase) {
        AssistantPhase.off => 'Assistant off — type a command, or tap to talk anyway',
        AssistantPhase.idle => 'Tap to talk',
        AssistantPhase.listening => 'Listening…',
        AssistantPhase.acting => 'Working…',
        AssistantPhase.responding => 'Responding…',
      };
}

class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) => Container(
        width: 36,
        height: 4,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.outlineVariant,
          borderRadius: BorderRadius.circular(2),
        ),
      );
}

class _TranscriptText extends StatelessWidget {
  const _TranscriptText({required this.text, required this.live});

  final String text;
  final bool live;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final display = text.isEmpty ? (live ? 'Listening…' : '') : '"$text"';
    if (display.isEmpty) return const SizedBox.shrink();
    return Text(
      display,
      textAlign: TextAlign.center,
      style: Theme.of(context).textTheme.titleMedium?.copyWith(
            color: live ? scheme.primary : scheme.onSurface,
            fontStyle: live ? FontStyle.italic : FontStyle.normal,
          ),
    );
  }
}

class _ReplyBanner extends StatelessWidget {
  const _ReplyBanner({required this.ok, required this.reply});

  final bool ok;
  final String reply;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final color = ok ? scheme.primary : scheme.error;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: color.withValues(alpha: 0.4)),
      ),
      child: Row(
        children: [
          Icon(
            ok ? Icons.check_circle_outline : Icons.error_outline,
            color: color,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              reply,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

class _DeviceChips extends StatelessWidget {
  const _DeviceChips({required this.devices});

  final List<Device> devices;

  @override
  Widget build(BuildContext context) => Wrap(
        spacing: 8,
        runSpacing: 8,
        alignment: WrapAlignment.center,
        children: [
          for (final device in devices)
            Chip(
              avatar: Icon(iconForKind(device.kind), size: 18),
              label: Text(device.name),
            ),
        ],
      );
}

/// "Which one?" prompt: tappable chips for each candidate. Tapping a chip
/// submits that device's name through [onPick] the same way typing it (or
/// saying it) would — [AssistantService] folds it into the pending intent.
class _DisambiguationChips extends StatelessWidget {
  const _DisambiguationChips({required this.devices, required this.onPick});

  final List<Device> devices;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text('Which one?', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.center,
          children: [
            for (final device in devices)
              ActionChip(
                avatar: Icon(iconForKind(device.kind), size: 18),
                label: Text(device.name),
                onPressed: () => onPick(device.name),
              ),
          ],
        ),
      ],
    );
  }
}

class _CommandTextField extends StatelessWidget {
  const _CommandTextField({required this.controller, required this.onSubmit});

  final TextEditingController controller;
  final ValueChanged<String> onSubmit;

  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        textInputAction: TextInputAction.send,
        decoration: InputDecoration(
          hintText: 'Type a command…',
          prefixIcon: const Icon(Icons.keyboard_outlined),
          suffixIcon: IconButton(
            icon: const Icon(Icons.send_outlined),
            onPressed: () => onSubmit(controller.text),
          ),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(16)),
        ),
        onSubmitted: onSubmit,
      );
}
