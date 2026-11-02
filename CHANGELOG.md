# Changelog

## 1.1.0 - 2026-10-16

### Added
- Linux desktop builds for x64 and arm64 (`HomeDeck-<version>-linux-x64.tar.gz` and
  `HomeDeck-<version>-linux-arm64.tar.gz`), built, tested and smoke-run in CI and attached to
  every tagged release next to the Android APKs.
- Google Home connector for Android, built on the Home APIs (SDK 17.1.0): permission flow,
  device listing, and on/off, brightness and thermostat commands. Release APKs now ship with
  it enabled. It works for the test users registered in the Google Home Developer Console
  until Google's certification is complete; see `docs/google-home-setup.md`.
- Alexa-style background listening on Android: a microphone foreground service keeps the
  wake-word engine alive while the app is in the background or the phone is locked, with
  the required persistent notification and a one-time battery-optimisation exemption request.

### Fixed
- Wake-word sensitivity mapping: the default sensitivity now maps to the spotter's recommended
  0.25 posterior threshold instead of 0.5, so the default setting actually triggers.

### Changed
- `app/pubspec.yaml` now carries the release version (it stayed at 0.1.0+1 for v1.0.0 and
  v1.0.1), so the Android `versionName` and `versionCode` follow the release.

## 1.0.1 - 2026-08-07

### Fixed
- Analyzer infos that failed `flutter analyze` in CI.

## 1.0.0 - 2026-08-07

First release: per-ABI Android APKs.
