# Integration notes — Hue and Google Home connectors

Written because the implementation task for these connectors was scoped to
`app/lib/connectors/hue/`, `app/lib/connectors/googlehome/`, and
`app/test/connectors/` only — `main.dart`, `pubspec.yaml`, `settings_store.dart`
etc. were explicitly off limits. Everything below is what someone wiring
these connectors into the rest of the app needs to do in those files.

## Both connectors

Neither connector reads `SharedPreferences` itself — both take their config
through a `configure()` method, same as `HaConnector`/`MqttConnector`. The
wiring point is wherever those two are already constructed and configured
(likely `main.dart` alongside the other connectors, driven by
`settings_store.dart`).

```dart
final hue = HueConnector(registry);
final ghome = GoogleHomeConnector(registry);
// ... register with ConnectorsService the same way ha/mqtt are registered ...
```

## Hue (`app/lib/connectors/hue/`)

No pubspec changes needed — `http` and `multicast_dns` are already
dependencies.

**Settings keys expected** (add wherever HA's `baseUrl`/`token` keys live in
`settings_store.dart`):

- `hue_bridge_ip` (String?) — the paired bridge's LAN IP.
- `hue_application_key` (String?) — the key returned by
  `HueConnector.pairWithBridge(ip)` / `HueClient.pairWithBridge(ip)`.

**Configure call:**

```dart
await hue.configure(bridgeIp: settings.hueBridgeIp, applicationKey: settings.hueApplicationKey);
```

**Pairing UI flow** (new settings screen, not part of this task):

1. Call `HueConnector.discoverBridges()` (or let the user type an IP) to get
   a candidate bridge IP.
2. Show "press the link button on your bridge", then call
   `connector.pairWithBridge(ip)`.
3. On `result.ok == false` with the link-button message, let the user retry
   (they have ~30s per button press).
4. On success, persist `result.applicationKey` and the bridge IP via
   `settings_store.dart`, then call `configure(...)` with both.

No changes to `AndroidManifest.xml`, `build.gradle`, or any native project
files — the bridge is reached over plain HTTPS on the LAN via `dart:io`.

## Google Home (`app/lib/connectors/googlehome/`)

**This connector is a Dart-side scaffold only.** It will report
`ConnectorStatus.error` with `GoogleHomeConnector.setupMessage` forever until
a native Android implementation exists. See `docs/google-home-setup.md` for
the full native-side plan. Summary of what's needed outside this task's file
boundary, once that work starts:

- **`app/android/app/build.gradle`**: add the Home APIs / Play services
  dependency (see docs/google-home-setup.md for the exact coordinate — it
  changes with Play services versioning, so check current docs rather than
  hardcoding a version here).
- **`app/android/app/src/main/AndroidManifest.xml`**: OAuth client
  configuration / any required `<meta-data>` the Home SDK setup docs specify.
- **A new Kotlin file** (e.g. `MainActivity.kt` or a dedicated
  `GoogleHomeChannelHandler.kt`) registering a
  `MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "homedeck/googlehome")`
  and implementing `init`, `listDevices`, `execute` — see
  `docs/google-home-setup.md` for the method contract this Dart connector
  expects and a Kotlin code sketch.

**Settings key expected:** a single `ghome_enabled` (bool) toggle — there are
no credentials to store on the Dart side; the native Home APIs own their own
OAuth/consent state.

```dart
await ghome.configure(enabled: settings.ghomeEnabled);
```

**Platform gating:** this connector is meaningless on Linux/desktop builds.
Whoever wires it into settings should hide or disable the toggle off-Android
(e.g. `Platform.isAndroid`) rather than showing a control that can never
leave the "needs setup" state there.
