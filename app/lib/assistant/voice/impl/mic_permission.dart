import 'package:permission_handler/permission_handler.dart';

/// Requests microphone access if not already granted.
///
/// Both wake-word engines and [SpeechRecognizer] need `RECORD_AUDIO`; this is
/// the single place that asks, so the "audio never leaves this device"
/// permission screen only has to trigger one system prompt. Returns `true`
/// once the mic is usable (already granted or granted just now).
///
/// Callers (`start()`/`available`) treat this as fail-soft, so it never
/// throws: if the platform channel itself is unavailable — no
/// permission_handler platform binding, which is also what a plain unit
/// test sees — that's indistinguishable from "permission not usable" here.
Future<bool> ensureMicPermission() async {
  try {
    final status = await Permission.microphone.status;
    if (status.isGranted) return true;

    final result = await Permission.microphone.request();
    return result.isGranted;
  } catch (_) {
    return false;
  }
}
