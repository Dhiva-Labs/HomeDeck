# Turning an old phone or tablet into a wall panel

## Which path does your device take?

| Device | What to install |
|---|---|
| Android 7.0 or newer | The HomeDeck APK |
| Android 5.0–6.0 | The APK, but see *Android 5 and 6* below |
| Android 4.x and older | Nothing — open the hub's web dashboard in the browser |
| Old iPad / iPhone | Nothing — open the hub's web dashboard in Safari |

The web dashboard is not a lesser fallback for its purpose. Camera feeds work,
device list works, Wake-on-LAN works, and it needs no install, no store
account, and no JavaScript.

## Installing the app

Pick the APK matching the device's CPU. `armeabi-v7a` covers essentially every
32-bit phone; `arm64-v8a` covers 64-bit ones from roughly 2015 onward. Using
the right one saves about 3 MB, which matters on a device with 8 GB of storage.

```bash
flutter build apk --release --split-per-abi
```

Then either `adb install` it, or copy the file to the device and open it after
allowing installs from unknown sources.

### Android 5 and 6

The app is written to run on Android 5.0, but `minSdk` in
`app/android/app/build.gradle.kts` currently resolves to Flutter's default of
24 (Android 7.0), so a build made today will refuse to install on older
devices. Set it explicitly:

```kotlin
minSdk = 21
```

## First run

1. Connect to the same Wi-Fi as everything else.
2. Open HomeDeck, tap **Get started**.
3. **Devices → Scan network**. On a slow device the sweep takes a minute or so.
4. Name what you recognize and assign rooms — the dashboard groups by room.
5. **Cameras → scan** for ONVIF cameras, or add an RTSP URL by hand.
6. If you run Home Assistant, connect it in **Settings** — see
   [home-assistant-setup.md](home-assistant-setup.md).

## Panel mode

In **Settings → Panel**:

- **Keep screen on** — required for wall use, otherwise Android sleeps.
- **Dim overnight** — lays a scrim over the screen between the hours you pick
  (23:00–06:00 by default) so the panel doesn't light the room. Tap to wake it
  for 30 seconds. The first tap only wakes; it won't also toggle whatever was
  underneath your finger.
- **Performance mode** — leave on **Auto**. The app checks RAM, CPU cores and
  Android version at startup and reduces effects when the hardware warrants it.
  Settings tells you what it decided and why.

## Making it boot into HomeDeck

To stop a stray swipe leaving the panel, set HomeDeck as the launcher:
**Android Settings → Apps → Default apps → Home app**. To undo it, uninstall
HomeDeck or pick the original launcher again. On Android 5 and 6 the setting
lives under **Settings → Home**.

## Battery and power

A tablet plugged in permanently at 100% will swell its battery within a year or
two. Options, best first:

1. **Remove the battery** and run from the charger, if the device allows it.
   Some tablets won't boot without one.
2. **A smart plug on a schedule** — charge for a couple of hours a day, run on
   battery the rest. This is the practical answer for most people, and it's a
   nice use for a device HomeDeck can already control.
3. **Accept it.** A swollen battery in a wall-mounted tablet is a real fire
   risk, so check on it occasionally: if the screen starts lifting from the
   bezel, stop using it.

Keep the panel out of direct sunlight. Heat kills these batteries faster than
the charging does.

## Getting more out of weak hardware

- **Run the hub** ([hub/README.md](../hub/README.md)). It transcodes cameras to
  MJPEG, so the panel stops decoding H.264 entirely — the single biggest win on
  an old device.
- **Prefer sub-streams.** ONVIF cameras usually expose a low-resolution second
  profile; HomeDeck picks it automatically in performance mode.
- **Add snapshot URLs** for your cameras. Grid tiles then poll a still image
  instead of holding a video stream open.
- **Fewer cameras per screen.** The grid is cheap, but each visible tile is
  still a periodic HTTP request.

## Troubleshooting

**The scan finds nothing** — the device is probably on a guest network, which
isolates clients from each other. Move it to the main network.

**Cameras appear but won't play** — check credentials first, then try the hub.
Some old GPUs can't decode a 4 MP main stream at all, and the hub sidesteps it.

**Wake-on-LAN does nothing** — it must be enabled in the target PC's BIOS *and*
its network adapter settings, and it generally doesn't work over Wi-Fi. The hub
is more reliable here because it's usually on Ethernet.

**The app feels sluggish** — check what Auto decided in Settings. If it says
the hardware looks capable but it doesn't feel that way, force performance mode
**On**.
