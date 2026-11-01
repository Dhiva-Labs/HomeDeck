#!/usr/bin/env bash
# Makes an installed tree self-contained for the AppImage and the Flatpak,
# which cannot depend on a distribution's libmpv package.
#
# usage: bundle-libmpv.sh <tree> <lib dir, relative to the tree> [<tool>...]
#
# <lib dir> is the Flutter bundle's lib/ (the executable's RUNPATH is
# $ORIGIN/lib). libmpv.so.2 goes there (the app's own copy, or this runner's
# if the tree has none), and its dependency chain (ffmpeg, libass,
# libplacebo, ...), as this Ubuntu runner resolves it, into <lib dir>/mpv/.
# RUNPATH ($ORIGIN) ties the chain together, so no LD_LIBRARY_PATH is needed
# and the host's own copies of the shared desktop libraries are not shadowed
# for the rest of the process. Every library in <lib dir> that needs
# libmpv.so.2 (the media_kit plugin) gets RUNPATH $ORIGIN too, in place of
# the build machine's paths it was linked with.
#
# Each <tool> (a program the app runs, e.g. ffmpeg) is copied from this
# runner into <lib dir>/../tools/bin/, with its libraries in the same mpv/
# folder.
#
# Left to the host: glibc and the compiler runtime, GTK 3 and the libraries
# it is built on, the X11/Wayland client libraries, the GL/GPU stack (it must
# match the host's drivers) and ALSA (it must match the host's sound setup).
# That is what every GTK desktop and the GNOME Flatpak runtime have. Every
# other library in the chain is copied, with its Debian copyright file.
#
# Needs libmpv2 (and the tools) installed on the runner, so ldd resolves the
# whole chain, patchelf, and dpkg (to find each library's package).
set -euo pipefail
[ $# -ge 2 ] || { echo "usage: $0 <tree> <lib dir> [<tool>...]" >&2; exit 2; }
tree="$(cd "$1" && pwd)"
libdir="$tree/$2"
shift 2
tools=("$@")
deps="$libdir/mpv"

host_lib() {
  case "$1" in
    # glibc and the compiler runtime
    ld-linux*|libc.so.*|libm.so.*|libdl.so.*|libpthread.so.*|librt.so.*|libresolv.so.*|\
    libutil.so.*|libmvec.so.*|libanl.so.*|libnss_*|libthread_db.so.*|libstdc++.so.*|libgcc_s.so.*) ;;
    # GTK 3 and what it is built on
    libgtk-3.so.*|libgdk-3.so.*|libgdk_pixbuf-2.0.so.*|libglib-2.0.so.*|libgobject-2.0.so.*|\
    libgio-2.0.so.*|libgmodule-2.0.so.*|libgthread-2.0.so.*|libpango-1.0.so.*|libpangocairo-1.0.so.*|\
    libpangoft2-1.0.so.*|libcairo.so.*|libcairo-gobject.so.*|libharfbuzz.so.*|libfreetype.so.*|\
    libfontconfig.so.*|libfribidi.so.*|libatk-1.0.so.*|libatk-bridge-2.0.so.*|libatspi.so.*|\
    libepoxy.so.*|libpixman-1.so.*|libpng16.so.*|libz.so.*|libexpat.so.*|libdbus-1.so.*|libffi.so.*|\
    libmount.so.*|libblkid.so.*|libselinux.so.*|libpcre2-8.so.*) ;;
    # X11 and Wayland client libraries
    libX11.so.*|libX11-xcb.so.*|libxcb.so.*|libxcb-render.so.*|libxcb-shm.so.*|libXau.so.*|\
    libXext.so.*|libXrender.so.*|libXfixes.so.*|libXi.so.*|libXrandr.so.*|libXcursor.so.*|\
    libXdamage.so.*|libXcomposite.so.*|libXinerama.so.*|libwayland-client.so.*|\
    libwayland-cursor.so.*|libwayland-egl.so.*|libwayland-server.so.*|libxkbcommon.so.*) ;;
    # GL and the GPU, sound
    libGL.so.*|libGLX.so.*|libGLdispatch.so.*|libOpenGL.so.*|libEGL.so.*|libgbm.so.*|\
    libdrm.so.*|libglapi.so.*|libasound.so.*) ;;
    *) return 1 ;;
  esac
}

# The package that owns a file. Not every Ubuntu package has moved its files
# to /usr yet, so try the /lib spelling too.
pkg_of() {
  local out
  out="$(dpkg -S "$1" 2> /dev/null || dpkg -S "${1#/usr}" 2> /dev/null)" ||
    { echo "no package owns $1" >&2; return 1; }
  printf '%s\n' "$out" | head -n 1 | cut -d: -f1
}

sys_mpv="$(ldconfig -p | awk '$1 == "libmpv.so.2" { print $NF; exit }')"
[ -n "$sys_mpv" ] || { echo "libmpv.so.2 is not installed on this runner (apt-get install libmpv2)" >&2; exit 1; }
sys_mpv="$(readlink -f "$sys_mpv")"
mpv="$libdir/libmpv.so.2"
if [ ! -f "$mpv" ]; then
  # The app links the system libmpv instead of carrying its own copy.
  install -Dm644 "$sys_mpv" "$mpv"
fi

# Where each soname resolves on this runner: ldd follows the whole chain.
declare -A path=()
resolve() {
  local soname arrow target rest
  while read -r soname arrow target rest; do
    [ "$arrow" = '=>' ] || continue
    if [ "$target" = not ]; then echo "ldd $1: $soname not found on this runner" >&2; exit 1; fi
    path["$soname"]="$target"
  done < <(ldd "$1")
}
resolve "$mpv"

mkdir -p "$deps/licenses"
queue=("$mpv")
packages=("$(pkg_of "$sys_mpv")")
for t in "${tools[@]}"; do
  real="$(readlink -f "$(command -v "$t")")"
  install -Dm755 "$real" "$libdir/../tools/bin/$t"
  patchelf --set-rpath '$ORIGIN/../../lib/mpv' "$libdir/../tools/bin/$t"
  resolve "$real"
  packages+=("$(pkg_of "$real")")
  queue+=("$libdir/../tools/bin/$t")
done

# Walk the NEEDED graph, stopping at host libraries, so only what the chain
# itself needs is copied (not the host libraries' own dependencies).
declare -A seen=()
copied=0
while [ "${#queue[@]}" -gt 0 ]; do
  f="${queue[0]}"
  queue=("${queue[@]:1}")
  while read -r soname; do
    [ -n "${seen[$soname]:-}" ] && continue
    seen["$soname"]=1
    host_lib "$soname" && continue
    [ "$soname" = libmpv.so.2 ] && continue
    src="${path[$soname]:-}"
    [ -n "$src" ] || { echo "$soname (needed by $(basename "$f")) did not resolve" >&2; exit 1; }
    real="$(readlink -f "$src")"
    install -m644 "$real" "$deps/$soname"
    patchelf --set-rpath '$ORIGIN' "$deps/$soname"
    packages+=("$(pkg_of "$real")")
    queue+=("$deps/$soname")
    copied=$((copied + 1))
  done < <(objdump -p "$f" | awk '$1 == "NEEDED" { print $2 }')
done
patchelf --set-rpath '$ORIGIN/mpv' "$mpv"
for f in "$libdir"/*.so*; do
  [ "$f" = "$mpv" ] && continue
  if objdump -p "$f" | awk '$1 == "NEEDED" { print $2 }' | grep -x libmpv.so.2 > /dev/null; then
    patchelf --set-rpath '$ORIGIN' "$f"
    echo "RUNPATH of ${f#"$tree"/} is now \$ORIGIN"
  fi
done

# Licences of what was copied, and the exact Ubuntu package versions, so the
# matching sources can be fetched (apt-get source <package>=<version>).
mapfile -t packages < <(printf '%s\n' "${packages[@]}" | sort -u)
for pkg in "${packages[@]}"; do
  cp "/usr/share/doc/$pkg/copyright" "$deps/licenses/$pkg.copyright"
done
dpkg-query -W -f '${Package} ${Version}\n' "${packages[@]}" > "$deps/licenses/PACKAGES.txt"

echo "bundled libmpv${tools[*]:+ and ${tools[*]}} with $copied libraries from ${#packages[@]} Ubuntu packages into ${deps#"$tree"/}:"
du -sh "$deps"
cat "$deps/licenses/PACKAGES.txt"
