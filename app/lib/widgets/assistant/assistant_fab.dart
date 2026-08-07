import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../../assistant/assistant_service.dart';
import '../../screens/assistant/assistant_sheet.dart';

/// Small floating mic button meant to be dropped into [Scaffold.floatingActionButton]
/// by whichever screen wants it (see INTEGRATION_NOTES.md — home_shell is the
/// obvious home).
///
/// Tap opens the tap-to-talk sheet ([showAssistantSheet]); long-press starts
/// listening immediately via [AssistantService.pushToTalk], skipping the
/// sheet for a one-breath "wake, speak, done" flow. Renders a muted style
/// (outline icon, dimmed) whenever [AssistantService.phase] is
/// [AssistantPhase.off].
///
/// Built from [Material] + [InkWell] rather than [FloatingActionButton]
/// wrapped in an outer [GestureDetector]: [FloatingActionButton] owns its
/// own tap recognizer, and a sibling long-press recognizer layered outside
/// it never wins the gesture arena against it. [InkWell] takes `onLongPress`
/// natively, so one recognizer set handles both gestures correctly.
class AssistantFab extends StatelessWidget {
  const AssistantFab({super.key});

  @override
  Widget build(BuildContext context) {
    final service = context.watch<AssistantService>();
    final scheme = Theme.of(context).colorScheme;
    final muted = service.phase == AssistantPhase.off;
    final listening = service.phase == AssistantPhase.listening;

    final background = muted
        ? scheme.surfaceContainerHighest
        : (listening ? scheme.primary : scheme.primaryContainer);
    final foreground = muted
        ? scheme.outline
        : (listening ? scheme.onPrimary : scheme.onPrimaryContainer);

    return Tooltip(
      message: muted
          ? 'Assistant off — tap to talk anyway'
          : 'Tap to talk, hold to speak now',
      child: Material(
        color: background,
        shape: const CircleBorder(),
        elevation: 6,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => showAssistantSheet(context),
          onLongPress: () => context.read<AssistantService>().pushToTalk(),
          child: SizedBox(
            width: 40,
            height: 40,
            child: Icon(
              muted ? Icons.mic_off_outlined : Icons.mic_outlined,
              color: foreground,
            ),
          ),
        ),
      ),
    );
  }
}
