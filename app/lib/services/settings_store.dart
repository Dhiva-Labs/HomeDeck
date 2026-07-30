import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

enum PerformanceMode { auto, on, off }

/// App settings backed by SharedPreferences. Loaded once at startup.
class SettingsStore extends ChangeNotifier {
  SettingsStore(this._prefs);

  final SharedPreferences _prefs;

  static Future<SettingsStore> load() async =>
      SettingsStore(await SharedPreferences.getInstance());

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
  /// In `auto`, Phase 7 adds device heuristics; until then auto == off.
  bool get lowFx => switch (performanceMode) {
        PerformanceMode.on => true,
        PerformanceMode.off => false,
        PerformanceMode.auto => false,
      };

  // ---- Panel / kiosk --------------------------------------------------------

  bool get keepScreenOn => _prefs.getBool('keepScreenOn') ?? false;
  set keepScreenOn(bool v) {
    _prefs.setBool('keepScreenOn', v);
    notifyListeners();
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

  // ---- MQTT (used from Phase 5) ---------------------------------------------

  String? get mqttBroker => _prefs.getString('mqttBroker');
  set mqttBroker(String? v) {
    v == null || v.isEmpty
        ? _prefs.remove('mqttBroker')
        : _prefs.setString('mqttBroker', v);
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
