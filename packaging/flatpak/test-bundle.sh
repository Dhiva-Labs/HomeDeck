#!/usr/bin/env bash
# Installs a Flatpak bundle and runs it, inside the Flatpak builder container.
#
# usage: test-bundle.sh <bundle.flatpak> <app id> <window title regex>
#
#   1. `flatpak install --bundle`, as a user would (the runtime is already
#      in the image).
#   2. Inside the sandbox, every ELF file under /app must find all of its
#      libraries in /app or the runtime (the dynamic loader's --list, which
#      is what ldd runs).
#   3. Under Xvfb, `flatpak run` must show a visible window with the given
#      title and still be running 5 s later, with no loader errors.
#
# SANDBOX_TOOLS (optional): programs the app runs; the log shows which of
# them the runtime has. SANDBOX_TEST (optional): a bash script run inside the
# sandbox after step 2, which must exit 0 (e.g. the bundled tools doing the
# app's jobs).
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ $# -eq 3 ] || { echo "usage: $0 <bundle.flatpak> <app id> <window title regex>" >&2; exit 2; }
bundle="$1" app="$2" title="$3"
# flatpak run wants a runtime directory and a session bus; the container has
# neither, so make one and run every sandbox under its own dbus-run-session.
export XDG_RUNTIME_DIR=/tmp/xdg-runtime
mkdir -p -m 700 "$XDG_RUNTIME_DIR"

echo "::group::install $bundle"
flatpak install -y --noninteractive --bundle "$bundle"
flatpak info "$app"
flatpak info --show-permissions "$app"
echo "::endgroup::"

echo "::group::libraries inside the sandbox"
dbus-run-session -- flatpak run --env=SANDBOX_TOOLS="${SANDBOX_TOOLS:-}" --command=bash "$app" -c '
  set -euo pipefail
  case "$(uname -m)" in
    x86_64) loader=/lib64/ld-linux-x86-64.so.2 ;;
    aarch64) loader=/lib/ld-linux-aarch64.so.1 ;;
  esac
  n=0 missing=0
  while IFS= read -r -d "" f; do
    [ "$(head -c 4 "$f" | od -An -tx1 | tr -d " \n")" = 7f454c46 ] || continue
    n=$((n + 1))
    if "$loader" --list "$f" 2>&1 | grep "not found" > /dev/null; then
      echo "missing libraries for $f:"
      "$loader" --list "$f" 2>&1 | grep "not found"
      missing=1
    fi
  done < <(find /app -type f -print0)
  echo "$n ELF files checked"
  for t in $SANDBOX_TOOLS; do
    if p="$(command -v "$t")"; then echo "runtime has $t: $p"; else echo "runtime has no $t"; fi
  done
  [ "$n" -gt 0 ] && [ "$missing" = 0 ]
'
echo "::endgroup::"

if [ -n "${SANDBOX_TEST:-}" ]; then
  echo "::group::$SANDBOX_TEST inside the sandbox"
  dbus-run-session -- flatpak run --command=bash "$app" -s < "$SANDBOX_TEST"
  echo "::endgroup::"
fi

echo "::group::run $app under Xvfb"
cat > /tmp/flatpak-smoke.sh <<'EOS'
log=/tmp/flatpak-smoke.log
flatpak run "$APP" > "$log" 2>&1 &
pid=$!
ok=0
for i in $(seq 1 120); do
  if ! kill -0 "$pid" 2> /dev/null; then
    wait "$pid" && rc=0 || rc=$?
    echo "flatpak run exited early with status $rc"
    break
  fi
  if python3 "$HERE/find-window.py" "$TITLE"; then
    echo "window is up after ${i}s"
    sleep 5
    if kill -0 "$pid" 2> /dev/null; then ok=1; else echo "the app died after showing its window"; fi
    break
  fi
  sleep 1
done
[ "$ok" = 1 ] || echo "no visible window matching '$TITLE'"
kill "$pid" 2> /dev/null
cat "$log"
if grep -E 'error while loading shared libraries|cannot open shared object|undefined symbol' "$log"; then ok=0; fi
[ "$ok" = 1 ]
EOS
APP="$app" TITLE="$title" HERE="$here" \
  xvfb-run -a -s '-screen 0 1280x800x24' dbus-run-session -- bash /tmp/flatpak-smoke.sh
echo "::endgroup::"
echo "$app: OK"
