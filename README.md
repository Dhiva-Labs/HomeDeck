# HomeDeck

**One control panel for your whole home — and a second life for that old phone or tablet.**

HomeDeck connects to Home Assistant, to IoT devices directly, to plain network
devices that aren't "smart" at all, and to security cameras of any brand. It is
built to run well on hardware everyone else has given up on.

## What it connects to

| Source | How it gets in | Status |
|---|---|---|
| **Any network device** (PC, NAS, printer, router, TV) | TCP sweep + ARP + mDNS + SSDP + NetBIOS names | Working |
| **Security cameras, any brand** | ONVIF WS-Discovery, or a manual RTSP/HTTP URL | Working |
| **Analog cameras** | The DVR/encoder's RTSP channel, added manually | Working |
| **Home Assistant** | mDNS autodetect, REST + WebSocket | Working |
| **MQTT devices** (ESP32, Tasmota, Zigbee2MQTT, Shelly) | Broker connection, Home Assistant discovery topics | Working |
| **Ancient devices** (pre-Android 5, old iPads) | Retro web dashboard served by the Go hub | Built, uncompiled |

Devices from every source are normalized into one `Device` model, so the
dashboard treats a Home Assistant light and a bare network host the same way:
name it, put it in a room, act on it.

## Why it works on old hardware

Old phones are a great control panel and a terrible video decoder. HomeDeck is
built around that:

- **Grids never decode video.** Camera tiles poll a still-image snapshot; a real
  stream opens only when you tap into fullscreen. Twelve cameras on the wall
  cost one HTTP request each, not twelve H.264 decodes.
- **Sub-streams by default.** ONVIF cameras expose a low-res profile alongside
  the main one. On weak devices HomeDeck picks the small one automatically.
- **Capped video surface.** In performance mode the decode target is capped at
  480p regardless of what the camera sends.
- **Performance mode decides for itself.** At startup the app reads RAM, CPU
  cores and Android version and reduces effects when the hardware warrants it,
  telling you in Settings what it chose and why.
- **Overnight dimming** so a wall panel doesn't light the room; the first tap
  wakes it without also toggling whatever was under your finger.
- **Per-ABI APKs**, so a 32-bit device installs 29 MB instead of a fat
  universal build.
- **Wakelock and panel mode** for always-on wall use.

## Repo layout

```
home_deck/
├── app/     Flutter app (Android + Linux)
│   └── lib/
│       ├── models/       Device, Camera
│       ├── connectors/   netscan/, camera/, ha/, mqtt/, hub/  (one per source)
│       ├── services/     device_registry, camera_store, settings_store, connectors_service
│       ├── screens/      dashboard, devices, cameras, camera_view, settings, onboarding
│       └── widgets/      device_tile, camera_tile, ptz_pad
└── hub/     Go hub: LAN scanner, Wake-on-LAN, ffmpeg MJPEG restreamer,
              and the retro dashboard for devices Flutter can't target
```

Connectors are the extension point: each one discovers devices, pushes them into
the `DeviceRegistry`, and executes actions for the devices it owns. Adding MQTT
or the hub means adding a connector, not touching the UI.

See [docs/home-assistant-setup.md](docs/home-assistant-setup.md) for connecting
Home Assistant, including installing it if you don't run it yet.

## Building

```bash
cd app && flutter pub get && flutter test
```

Android release APKs (per-ABI):

```bash
flutter build apk --release --split-per-abi
```

If Gradle reports `JAVA_HOME is not set`, point it at Android Studio's bundled
JDK:

```bash
export JAVA_HOME=/snap/android-studio/current/jbr
```

Linux desktop needs mpv's development headers for video playback:

```bash
sudo apt install libmpv-dev
```

Without it the app still analyzes and tests clean, but `flutter build linux`
fails at the CMake step with `PkgConfig::mpv ... target was not found`.

## Verification tools

`app/tool/` holds throwaway probes that exercise the networking code against a
real LAN, without needing a GUI:

```bash
dart run tool/scan_probe.dart      # sweeps the subnet, prints live hosts
dart run tool/camera_probe.dart    # ONVIF discovery; pass user pass to fetch streams
```

See [docs/old-device-setup.md](docs/old-device-setup.md) for putting a panel on
a wall, including launcher mode and the battery question.

## Known gaps

- **`minSdk`** in `app/android/app/build.gradle.kts` currently resolves to
  Flutter's default of 24 (Android 7.0). Supporting the Android 5–6 devices in
  scope needs `minSdk = 21` set explicitly there.
- **The hub has never been compiled.** There is no Go toolchain on the machine
  it was written on, so `go build` was not run and none of it has been
  exercised against a live camera. The Dart side that talks to it is tested.
- **The MQTT broker connection is untested** — no broker was available. Message
  routing and payload parsing are covered end to end; the socket plumbing is
  not.
- **Linux desktop video** needs `sudo apt install libmpv-dev`, which could not
  be installed here.
