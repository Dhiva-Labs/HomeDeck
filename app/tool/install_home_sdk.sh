#!/usr/bin/env bash
# Install the Google Home APIs SDK for Android builds made with -PhomeApis.
#
#   tool/install_home_sdk.sh
#
# The SDK zip is a maven repository layout. It is unpacked into
# ~/.m2/repository, where app/android resolves play-services-home from
# mavenLocal(). Used by .github/workflows/release.yml and android-home.yml.
#
# Only the newest SDK zip sits at the top of the bucket. When Google publishes
# a new one, the previous zip moves to deprecated/ (1.11.0 moved there when
# 1.11.1 came out on 2026-10-22), so a fixed top-level URL breaks every
# release. The pinned version is therefore fetched from deprecated/ when the
# top level no longer has it, with a warning. To move to a newer SDK, bump
# SDK_VERSION to the current zip (listed on
# https://developers.home.google.com/apis/android/sdk) and let the
# android-home workflow confirm that src/homeapis still compiles against it.
set -euo pipefail

SDK_VERSION="${HOME_SDK_VERSION:-1_11_1}"
BUCKET="https://storage.googleapis.com/home_sdk_android"
ZIP="home.android.sdk_${SDK_VERSION}.zip"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

http_status() { curl -sSIL --retry 3 -o /dev/null -w '%{http_code}' "$1"; }

url="$BUCKET/$ZIP"
status="$(http_status "$url")"
if [ "$status" = 404 ]; then
  url="$BUCKET/deprecated/$ZIP"
  status="$(http_status "$url")"
  if [ "$status" = 404 ]; then
    echo "::error::$ZIP is in neither $BUCKET/ nor $BUCKET/deprecated/. Check SDK_VERSION in app/tool/install_home_sdk.sh."
    exit 1
  fi
  echo "::warning::$ZIP has been superseded and moved to deprecated/ in the SDK bucket. Bump SDK_VERSION in app/tool/install_home_sdk.sh to the current SDK."
fi
if [ "$status" != 200 ]; then
  echo "::error::unexpected HTTP $status for $url"
  exit 1
fi

echo "downloading $url"
curl -fsSL --retry 3 -o "$tmp/home_sdk.zip" "$url"
mkdir -p "$HOME/.m2/repository"
unzip -o -q "$tmp/home_sdk.zip" -d "$HOME/.m2/repository"
ls "$HOME/.m2/repository/com/google/android/gms"
