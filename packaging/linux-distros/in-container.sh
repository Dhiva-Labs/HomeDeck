#!/usr/bin/env bash
# Runs inside a distribution container started by verify.sh.
# MODE: rpm (Fedora) | rpm-suse (openSUSE) | pacman (Arch) | appimage (Fedora)
# FILE: the package to install, under /pkgs.
set -euo pipefail
# shellcheck source=/dev/null
. /linux-distros/distro.conf

# Display and GL stack for the GUI smoke test, per distribution: what a
# desktop installation has anyway (Flutter loads EGL/GL at run time, so the
# package itself does not depend on it). xdotool finds the app's window;
# SMOKE_PACKAGES_<DISTRO> from distro.conf adds what a SMOKE_SCRIPT needs.
# shellcheck disable=SC2086
case "$MODE" in
  rpm|appimage)
    dnf -y -q install file findutils which procps-ng \
      xorg-x11-server-Xvfb xorg-x11-xauth mesa-dri-drivers mesa-libEGL mesa-libGL \
      dbus-daemon xdotool ${SMOKE_PACKAGES_FEDORA:-}
    ;;
  rpm-suse)
    zypper -n -q --gpg-auto-import-keys refresh
    # xvfb-run needs awk but does not require it, and Tumbleweed's
    # dbus-run-session lives in dbus-1-daemon (dbus-1 is dbus-broker now).
    zypper -n -q install file findutils which procps gawk \
      xvfb-run Mesa-dri Mesa-libEGL1 Mesa-libGL1 dbus-1 dbus-1-daemon xdotool ${SMOKE_PACKAGES_SUSE:-}
    ;;
  pacman)
    pacman -Syu --noconfirm --needed -q file findutils which procps-ng \
      xorg-server-xvfb xorg-xauth mesa dbus xdotool ${SMOKE_PACKAGES_ARCH:-}
    ;;
esac

case "$MODE" in
  rpm)      dnf -y install "$FILE"; files() { rpm -ql "$NAME"; } ;;
  rpm-suse) zypper -n install --allow-unsigned-rpm "$FILE"; files() { rpm -ql "$NAME"; } ;;
  pacman)   pacman -U --noconfirm "$FILE"; files() { pacman -Qlq "$NAME"; } ;;
  appimage)
    # The libraries an AppImage expects from the host: GTK 3 and friends,
    # plus whatever distro.conf lists for this app.
    # shellcheck disable=SC2086
    dnf -y -q install ${APPIMAGE_HOST_PACKAGES_FEDORA:-gtk3}
    cp "$FILE" /tmp/app.AppImage
    chmod +x /tmp/app.AppImage
    (cd /tmp && /tmp/app.AppImage --appimage-extract > /dev/null)
    files() { find /tmp/squashfs-root -type f; }
    ;;
  *) echo "unknown MODE $MODE" >&2; exit 2 ;;
esac

# Every ELF file the package installed must find all of its libraries. The
# package's own library directories go on LD_LIBRARY_PATH, as the app's
# RPATH/$ORIGIN would supply them at run time, so only libraries missing
# from the distribution are reported.
mapfile -t elfs < <(files | while IFS= read -r f; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  [ "$(head -c 4 "$f" | od -An -tx1 | tr -d ' \n')" = 7f454c46 ] && echo "$f"
done)
libdirs="$(for f in "${elfs[@]}"; do case "$f" in *.so|*.so.*) dirname "$f" ;; esac; done | sort -u | paste -sd:)"
missing=0
for f in "${elfs[@]}"; do
  # grep > /dev/null, not grep -q: under pipefail an early exit of grep can
  # kill ldd with SIGPIPE and turn a match into "false".
  if LD_LIBRARY_PATH="$libdirs" ldd "$f" 2>&1 | grep 'not found' > /dev/null; then
    echo "missing libraries for $f:"
    LD_LIBRARY_PATH="$libdirs" ldd "$f" | grep 'not found'
    missing=1
  fi
done
echo "${#elfs[@]} ELF files checked with ldd"
[ "$missing" = 0 ] || exit 1

# Smoke test. CLI tools: SMOKE_CMD must exit 0. GUI apps: GUI_CMD must
# still be running after SMOKE_SECONDS under Xvfb, with no loader errors; with
# GUI_WINDOW set, a visible window whose title matches it must appear within
# SMOKE_SECONDS and the app must still be running 5 s later.
if [ "$MODE" = appimage ]; then
  export APPIMAGE_EXTRACT_AND_RUN=1
  cmd_prefix=/tmp/app.AppImage
else
  cmd_prefix=
fi
if [ -n "${SMOKE_CMD:-}" ]; then
  if [ -n "$cmd_prefix" ]; then
    # SMOKE_CMD's first word is the installed command; the AppImage replaces it.
    read -r -a words <<< "$SMOKE_CMD"
    "$cmd_prefix" "${words[@]:1}"
  else
    bash -c "$SMOKE_CMD"
  fi
fi
if [ -n "${GUI_CMD:-}" ]; then
  if [ -n "$cmd_prefix" ]; then gui=("$cmd_prefix"); else read -r -a gui <<< "$GUI_CMD"; fi
fi
if [ -n "${GUI_CMD:-}" ] && [ -n "${SMOKE_SCRIPT:-}" ]; then
  # The repository's own smoke test (relative to the repository root), which
  # proves more than a window: it gets the command to start as $1.
  xvfb-run -a -s '-screen 0 1280x800x24' dbus-run-session -- bash "/repo/$SMOKE_SCRIPT" "${gui[@]}"
elif [ -n "${GUI_CMD:-}" ]; then
  cat > /tmp/smoke.sh <<'EOS'
log=/tmp/smoke.log
"$@" > "$log" 2>&1 &
pid=$!
secs="${SMOKE_SECONDS:-20}"
shown=0
for i in $(seq 1 "$secs"); do
  kill -0 "$pid" 2> /dev/null || break
  if [ -n "${GUI_WINDOW:-}" ] && xdotool search --onlyvisible --name "$GUI_WINDOW" > /dev/null 2>&1; then
    echo "window '$GUI_WINDOW' is up after ${i}s"
    shown=1
    sleep 5
    break
  fi
  sleep 1
done
if kill -0 "$pid" 2> /dev/null; then
  echo "still running"
  kill "$pid"
  ok=1
  if [ -n "${GUI_WINDOW:-}" ] && [ "$shown" = 0 ]; then
    echo "no visible window matching '$GUI_WINDOW' after ${secs}s"
    ok=0
  fi
else
  wait "$pid" && rc=0 || rc=$?
  echo "exited early with status $rc"
  ok=0
fi
cat "$log"
if grep -E 'error while loading shared libraries|cannot open shared object|undefined symbol' "$log"; then ok=0; fi
[ "$ok" = 1 ]
EOS
  export HOME=/tmp/smoke-home SMOKE_SECONDS GUI_WINDOW
  mkdir -p "$HOME"
  xvfb-run -a -s '-screen 0 1280x800x24' dbus-run-session -- bash /tmp/smoke.sh "${gui[@]}"
fi
echo "$MODE: OK"
