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
}
