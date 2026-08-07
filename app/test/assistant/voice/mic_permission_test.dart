import 'package:flutter_test/flutter_test.dart';
import 'package:home_deck/assistant/voice/impl/mic_permission.dart';

// permission_handler needs a real platform binding to ever return granted;
// what matters for the "never throw" contract the voice engines rely on is
// that ensureMicPermission() resolves to a plain bool (false, here) instead
// of letting a MissingPluginException escape when no platform channel
// answers — which is exactly what happens today with no mock registered.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('resolves to false rather than throwing with no platform channel',
      () async {
    await expectLater(ensureMicPermission(), completion(isFalse));
  });
}
