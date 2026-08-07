import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'device_capabilities.dart';

enum PerformanceMode { auto, on, off }

/// Whether [hour] falls in the window from [start] to [end], which wraps
/// past midnight when start > end (23:00–06:00 being the normal case).
bool isWithinDimWindow(int hour, int start, int end) =>
    start <= end ? hour >= start && hour < end : hour >= start || hour < end;

/// App settings backed by SharedPreferences. Loaded once at startup.
class SettingsStore extends ChangeNotifier {
  SettingsStore(this._prefs, this.capabilities);

  final SharedPreferences _prefs;

  /// What the hardware can handle, detected once at startup. Drives
  /// [lowFx] when performance mode is left on `auto`.
  final DeviceCapabilities capabilities;

  static Future<SettingsStore> load() async => SettingsStore(
        await SharedPreferences.getInstance(),
        await DeviceCapabilities.detect(),
      );

  // ---- Onboarding -----------------------------------------------------------

  bool get onboarded => _prefs.getBool('onboarded') ?? false;
  set onboarded(bool v) {
    _prefs.setBool('onboarded', v);
    notifyListeners();
  }

  // ---- Performance / old-device mode ---------------------------------------

  PerformanceMode get performanceMode =>
      PerformanceMode.values.asNameMap()[_prefs.getString('performanceMode')] ??
      PerformanceMode.auto;
  set performanceMode(PerformanceMode v) {
    _prefs.setString('performanceMode', v.name);
    notifyListeners();
  }

  /// Whether reduced-effects mode is in force right now.
  bool get lowFx => switch (performanceMode) {
        PerformanceMode.on => true,
        PerformanceMode.off => false,
        PerformanceMode.auto => capabilities.isWeak,
      };

  // ---- Panel / kiosk --------------------------------------------------------

  bool get keepScreenOn => _prefs.getBool('keepScreenOn') ?? false;
  set keepScreenOn(bool v) {
    _prefs.setBool('keepScreenOn', v);
    notifyListeners();
  }

  /// Dim the panel overnight so a wall-mounted tablet isn't a nightlight.
  bool get dimAtNight => _prefs.getBool('dimAtNight') ?? false;
  set dimAtNight(bool v) {
    _prefs.setBool('dimAtNight', v);
    notifyListeners();
  }

  int get dimStartHour => _prefs.getInt('dimStartHour') ?? 23;
  set dimStartHour(int v) {
    _prefs.setInt('dimStartHour', v);
    notifyListeners();
  }

  int get dimEndHour => _prefs.getInt('dimEndHour') ?? 6;
  set dimEndHour(int v) {
    _prefs.setInt('dimEndHour', v);
    notifyListeners();
  }

  /// True when [now] falls inside the dim window, which may wrap midnight.
  bool isDimHour(DateTime now) {
    if (!dimAtNight) return false;
    return isWithinDimWindow(now.hour, dimStartHour, dimEndHour);
  }

  // ---- Home Assistant (used from Phase 4) -----------------------------------

  String? get haUrl => _prefs.getString('haUrl');
  set haUrl(String? v) {
    v == null || v.isEmpty ? _prefs.remove('haUrl') : _prefs.setString('haUrl', v);
    notifyListeners();
  }

  String? get haToken => _prefs.getString('haToken');
  set haToken(String? v) {
    v == null || v.isEmpty
        ? _prefs.remove('haToken')
        : _prefs.setString('haToken', v);
    notifyListeners();
  }

  // ---- MQTT -----------------------------------------------------------------

  String? get mqttBroker => _prefs.getString('mqttBroker');
  set mqttBroker(String? v) {
    v == null || v.isEmpty
        ? _prefs.remove('mqttBroker')
        : _prefs.setString('mqttBroker', v);
    notifyListeners();
  }

  int get mqttPort => _prefs.getInt('mqttPort') ?? 1883;
  set mqttPort(int v) {
    _prefs.setInt('mqttPort', v);
    notifyListeners();
  }

  String? get mqttUsername => _prefs.getString('mqttUsername');
  set mqttUsername(String? v) {
    v == null || v.isEmpty
        ? _prefs.remove('mqttUsername')
        : _prefs.setString('mqttUsername', v);
    notifyListeners();
  }

  String? get mqttPassword => _prefs.getString('mqttPassword');
  set mqttPassword(String? v) {
    v == null || v.isEmpty
        ? _prefs.remove('mqttPassword')
        : _prefs.setString('mqttPassword', v);
    notifyListeners();
  }

  // ---- Hub (used from Phase 6) ----------------------------------------------

  String? get hubUrl => _prefs.getString('hubUrl');
  set hubUrl(String? v) {
    v == null || v.isEmpty
        ? _prefs.remove('hubUrl')
        : _prefs.setString('hubUrl', v);
    notifyListeners();
  }

  // ---- Philips Hue -----------------------------------------------------------

  String? get hueBridgeIp => _prefs.getString('hueBridgeIp');
  set hueBridgeIp(String? v) {
    v == null || v.isEmpty
        ? _prefs.remove('hueBridgeIp')
        : _prefs.setString('hueBridgeIp', v);
    notifyListeners();
  }

  String? get hueAppKey => _prefs.getString('hueAppKey');
  set hueAppKey(String? v) {
    v == null || v.isEmpty
        ? _prefs.remove('hueAppKey')
        : _prefs.setString('hueAppKey', v);
    notifyListeners();
  }

  // ---- Voice assistant -------------------------------------------------------

  /// Master switch for hotword listening. Tap-to-talk works regardless.
  bool get assistantEnabled => _prefs.getBool('assistantEnabled') ?? false;
  set assistantEnabled(bool v) {
    _prefs.setBool('assistantEnabled', v);
    notifyListeners();
  }

  /// "sherpa" (open, custom name typed as text) or "porcupine".
  String get wakeEngine => _prefs.getString('wakeEngine') ?? 'sherpa';
  set wakeEngine(String v) {
    _prefs.setString('wakeEngine', v);
    notifyListeners();
  }

  /// The custom wake name. For the sherpa engine this is the keyword text
  /// itself; for Porcupine it selects a built-in keyword or names a .ppn.
  String get wakeWord => _prefs.getString('wakeWord') ?? 'jarvis';
  set wakeWord(String v) {
    _prefs.setString('wakeWord', v);
    notifyListeners();
  }

  /// Path to a custom-trained Porcupine .ppn model, if the user supplied one.
  String? get porcupineKeywordPath => _prefs.getString('porcupineKeywordPath');
  set porcupineKeywordPath(String? v) {
    v == null || v.isEmpty
        ? _prefs.remove('porcupineKeywordPath')
        : _prefs.setString('porcupineKeywordPath', v);
    notifyListeners();
  }

  String? get porcupineAccessKey => _prefs.getString('porcupineAccessKey');
  set porcupineAccessKey(String? v) {
    v == null || v.isEmpty
        ? _prefs.remove('porcupineAccessKey')
        : _prefs.setString('porcupineAccessKey', v);
    notifyListeners();
  }

  double get wakeSensitivity => _prefs.getDouble('wakeSensitivity') ?? 0.5;
  set wakeSensitivity(double v) {
    _prefs.setDouble('wakeSensitivity', v);
    notifyListeners();
  }

  bool get ttsEnabled => _prefs.getBool('ttsEnabled') ?? true;
  set ttsEnabled(bool v) {
    _prefs.setBool('ttsEnabled', v);
    notifyListeners();
  }

  double get ttsVolume => _prefs.getDouble('ttsVolume') ?? 1.0;
  set ttsVolume(double v) {
    _prefs.setDouble('ttsVolume', v);
    notifyListeners();
  }
}
