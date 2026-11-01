#!/usr/bin/env bash
# Builds the installed file tree the .rpm, Arch package, AppImage and
# Flatpak are made from, out of the Linux release tarball (HomeDeck ships no
# .deb):
#
#   /usr/lib/homedeck/                       the Flutter bundle (home_deck, lib/, data/)
#   /usr/bin/homedeck                        -> ../lib/homedeck/home_deck
#   /usr/share/applications/homedeck.desktop
#   /usr/share/icons/hicolor/192x192/apps/homedeck.png   (the Android launcher icon)
#
# usage: make-tree.sh <HomeDeck-<version>-linux-<arch>.tar.gz> <root>
#
# packaging/arch/PKGBUILD.in lays the AUR package out the same way.
set -euo pipefail
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
[ $# -eq 2 ] || { echo "usage: $0 <tarball> <root>" >&2; exit 2; }
tarball="$1" root="$2"

install -d "$root/usr/lib/homedeck" "$root/usr/bin"
tar -xzf "$tarball" --strip-components=1 -C "$root/usr/lib/homedeck"
[ -x "$root/usr/lib/homedeck/home_deck" ] ||
  { echo "$tarball has no home_deck at its top level" >&2; exit 1; }
ln -s ../lib/homedeck/home_deck "$root/usr/bin/homedeck"
install -Dm644 "$repo/packaging/linux/homedeck.desktop" \
  "$root/usr/share/applications/homedeck.desktop"
install -Dm644 "$repo/app/android/app/src/main/res/mipmap-xxxhdpi/ic_launcher.png" \
  "$root/usr/share/icons/hicolor/192x192/apps/homedeck.png"
(cd "$root" && find . -not -path '*/flutter_assets/*' | sort)
