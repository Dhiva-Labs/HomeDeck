#!/usr/bin/env bash
# Package the Linux release bundle into HomeDeck-<version>-linux-<arch>.tar.gz.
#
#   tool/build_tarball.sh [OUT_DIR] [VERSION]
#
# Run from the app/ directory after `flutter build linux --release`. The
# architecture comes from the machine (x86_64 -> x64, aarch64 -> arm64), so the
# same script serves both runners. VERSION defaults to the pubspec version;
# the release workflow passes the git tag (for example v1.0.1) so the file
# names line up with the APK assets.
set -euo pipefail

cd "$(dirname "$0")/.."

OUT_DIR="${1:-dist}"

case "$(uname -m)" in
  x86_64) ARCH=x64 ;;
  aarch64 | arm64) ARCH=arm64 ;;
  *)
    echo "error: unsupported machine '$(uname -m)' (x86_64 or aarch64)" >&2
    exit 1
    ;;
esac

VERSION="${2:-$(grep '^version:' pubspec.yaml | awk '{print $2}' | cut -d+ -f1)}"
RELEASE_DIR="build/linux/$ARCH/release"
NAME="HomeDeck-${VERSION}-linux-${ARCH}"

if [ ! -x "$RELEASE_DIR/bundle/home_deck" ]; then
  echo "error: $RELEASE_DIR/bundle/home_deck not found; run 'flutter build linux --release' first" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
tar -czf "$OUT_DIR/$NAME.tar.gz" --owner=0 --group=0 --sort=name \
  --transform "s,^bundle,$NAME," -C "$RELEASE_DIR" bundle
echo "$OUT_DIR/$NAME.tar.gz"
