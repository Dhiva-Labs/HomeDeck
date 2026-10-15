#!/usr/bin/env bash
# Install the Google Home APIs SDK for Android builds made with -PhomeApis.
#
#   tool/install_home_sdk.sh
#
# The SDK zip is a maven repository layout. It is unpacked into
# ~/.m2/repository, where app/android resolves play-services-home from
# mavenLocal(). Used by .github/workflows/release.yml and android-home.yml.
#
# Google deletes old SDK zips from the bucket: 1.10.0 now answers 404. When
# this script fails with a 404, bump SDK_VERSION to the current zip (listed on
# https://developers.home.google.com/apis/android/sdk) and let the
# android-home workflow confirm that src/homeapis still compiles against it.
set -euo pipefail

SDK_VERSION="${HOME_SDK_VERSION:-1_11_0}"
URL="https://storage.googleapis.com/home_sdk_android/home.android.sdk_${SDK_VERSION}.zip"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

echo "downloading $URL"
curl -fsSL --retry 3 -o "$tmp/home_sdk.zip" "$URL"
mkdir -p "$HOME/.m2/repository"
unzip -o -q "$tmp/home_sdk.zip" -d "$HOME/.m2/repository"
ls "$HOME/.m2/repository/com/google/android/gms"
