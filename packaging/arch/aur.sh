#!/usr/bin/env bash
# Renders the AUR PKGBUILD for one release and proves it builds.
#
# usage: aur.sh <amd64 release file> <arm64 release file> <outdir>
#
# The release files are what the PKGBUILD repackages (the .debs, or the
# tarballs for an app without a .deb). Fills PKGBUILD.in with the version,
# the release download URLs and the sha256 of both files, plus the files of
# this repository it downloads from the release tag (the licence, and
# AUR_SOURCES from distro.conf). Then, in an archlinux:latest container, it
# generates .SRCINFO, runs makepkg on the x86_64 sources (they are placed
# next to the PKGBUILD, so makepkg verifies the checksums without
# downloading), installs the result and checks every ELF file in it with
# ldd. Writes <name>-bin-<version>-aur.tar.gz holding PKGBUILD and .SRCINFO,
# ready to push to the AUR.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../.." && pwd)"
[ $# -eq 3 ] || { echo "usage: $0 <amd64 file> <arm64 file> <outdir>" >&2; exit 2; }
src_amd64="$(readlink -f "$1")"; src_arm64="$(readlink -f "$2")"
mkdir -p "$3"; out="$(cd "$3" && pwd)"
# shellcheck source=/dev/null
. "$here/../linux-distros/distro.conf"
# The optional lists distro.conf may leave out are empty.
for v in EXCLUDE PACKAGE_EXCLUDE RPM_REQUIRES RPM_RECOMMENDS ARCH_DEPENDS ARCH_OPTDEPENDS AUR_SOURCES; do
  declare -p "$v" > /dev/null 2>&1 || declare -a "$v=()"
done
: "${VERSION:?set VERSION}"
: "${GITHUB_REPO:?distro.conf must set GITHUB_REPO, e.g. Dhiva-Labs/BranchPilot}"
tag="${TAG_PREFIX-v}$VERSION"
sha() { sha256sum "$1" | cut -d' ' -f1; }

work="$(mktemp -d)"; trap 'rm -rf "$work"' EXIT
deps=""; for d in "${ARCH_DEPENDS[@]}"; do deps+="'$d' "; done
optdeps=""; for d in "${ARCH_OPTDEPENDS[@]}"; do optdeps+="'$d' "; done
sed -e "s|@NAME@|$NAME|g" -e "s|@VERSION@|$VERSION|g" \
    -e "s|@SUMMARY@|${SUMMARY//\'/}|g" -e "s|@HOMEPAGE@|$HOMEPAGE|g" \
    -e "s|@LICENSE@|$LICENSE|g" -e "s|@ARCH_DEPENDS@|${deps% }|g" \
    -e "s|@ARCH_OPTDEPENDS@|${optdeps% }|g" \
    -e "s|@RELEASE_URL@|https://github.com/$GITHUB_REPO/releases/download/$tag|g" \
    -e "s|@SRC_AMD64@|$(basename "$src_amd64")|g" -e "s|@SRC_ARM64@|$(basename "$src_arm64")|g" \
    -e "s|@SHA_AMD64@|$(sha "$src_amd64")|g" -e "s|@SHA_ARM64@|$(sha "$src_arm64")|g" \
    "$here/PKGBUILD.in" > "$work/PKGBUILD"

# Files of this repository at the release tag, saved as
# <pkgname>-<pkgver>-<file name> (package() refers to them by that name).
nl=$'\n'
sources="" sums=""
for f in ${LICENSE_FILE:+"$LICENSE_FILE"} "${AUR_SOURCES[@]}"; do
  sources+="  \"\$pkgname-\$pkgver-$(basename "$f")::https://raw.githubusercontent.com/$GITHUB_REPO/$tag/$f\"$nl"
  sums+="  '$(sha "$repo/$f")'$nl"
  cp "$repo/$f" "$work/$NAME-bin-$VERSION-$(basename "$f")"
done
# Files the Arch package from pack.sh leaves out are removed here too.
removes="" sep=$'\n  '
for p in "${EXCLUDE[@]}" "${PACKAGE_EXCLUDE[@]}"; do
  removes+="${removes:+$sep}rm -r \"\$pkgdir/$p\""
done
pkgbuild="$(cat "$work/PKGBUILD")"
pkgbuild="${pkgbuild//@SOURCES@$nl/$sources}"
pkgbuild="${pkgbuild//@SHA256SUMS@$nl/$sums}"
pkgbuild="${pkgbuild//@REMOVE@/${removes:-:}}"
printf '%s\n' "$pkgbuild" > "$work/PKGBUILD"
cp "$src_amd64" "$work/"
if grep -n '@[A-Z0-9_]*@' "$work/PKGBUILD"; then echo "unfilled placeholder" >&2; exit 1; fi

# makepkg refuses to run as root, so the build runs as a user made in the
# container; /build goes back to the runner's user at the end, or the tar
# below (and the cleanup) cannot read what makepkg wrote.
docker run --rm -v "$work:/build" -e HOST_IDS="$(id -u):$(id -g)" archlinux:latest bash -euo pipefail -c '
  trap "chown -R \"\$HOST_IDS\" /build" EXIT
  pacman -Syu --noconfirm --needed -q base-devel namcap
  useradd -m builder
  chown -R builder /build
  cd /build
  su builder -c "makepkg --printsrcinfo > .SRCINFO"
  su builder -c "makepkg --noconfirm --nodeps -f"
  namcap PKGBUILD
  pacman -U --noconfirm ./*-x86_64.pkg.tar.zst
  # Every ELF file the package installed finds its libraries on Arch. The
  # library directories of the package go on LD_LIBRARY_PATH, as the RUNPATH
  # of the executable supplies them at run time (Flutter plugins need
  # libflutter_linux_gtk.so from there, but keep the RUNPATH of the build
  # machine).
  files="$(pacman -Qlq "$(sed -n "s/^pkgname = //p" .SRCINFO)")"
  libdirs="$(for f in $files; do
    case "$f" in *.so|*.so.*) if [ -f "$f" ]; then dirname "$f"; fi ;; esac
  done | sort -u | paste -sd:)"
  missing=0 n=0
  for f in $files; do
    [ -f "$f" ] && [ ! -L "$f" ] || continue
    [ "$(head -c 4 "$f" | od -An -tx1 | tr -d " \n")" = 7f454c46 ] || continue
    n=$((n + 1))
    if LD_LIBRARY_PATH="$libdirs" ldd "$f" 2>&1 | grep "not found"; then echo "^ $f"; missing=1; fi
  done
  echo "$n ELF files checked"
  [ "$n" -gt 0 ] && [ "$missing" = 0 ]
  cat PKGBUILD .SRCINFO
'
tar -C "$work" -czf "$out/$NAME-bin-$VERSION-aur.tar.gz" PKGBUILD .SRCINFO
ls -l "$out/$NAME-bin-$VERSION-aur.tar.gz"
