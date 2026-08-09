import 'package:flutter/services.dart';

/// Dart side of `MethodChannel('homedeck/background')` — the Android
/// microphone foreground service that keeps hotword detection running with
/// the screen off or the phone locked ("Alexa mode").
///
/// Every call fails soft off-Android (or in tests): the assistant then
/// simply listens only while the app is on screen.
class BackgroundListening {
  static const _channel = MethodChannel('homedeck/background');

  static Future<bool> start() => _call('startListening');

  static Future<bool> stop() => _call('stopListening');

  /// Whether the app is exempt from battery optimization. Without this,
  /// aggressive OEM power managers kill the mic service shortly after the
  /// screen locks.
  static Future<bool> isBatteryExempt() =>
      _call('isIgnoringBatteryOptimizations');

  /// Fires the system dialog asking the user to exempt HomeDeck. Granting
  /// is their choice in the system UI.
  static Future<bool> requestBatteryExemption() =>
      _call('requestIgnoreBatteryOptimizations');

  static Future<bool> _call(String method) async {
    try {
      return await _channel.invokeMethod<bool>(method) ?? false;
    } on MissingPluginException {
      return false;
    } on PlatformException {
      return false;
    }
  }
}
