#!/usr/bin/env bash
# Starts HomeDeck and waits for proof that its Dart code is running. Run it
# inside a display, e.g.
#
#   xvfb-run -a dbus-run-session -- tool/smoke_linux.sh <command> [screenshot.png]
#
# The native runner titles the window home_deck before any Dart code runs, so
# the window alone proves little. What does: libapp.so (the AOT snapshot) is
# mapped into the app's process, libmpv is loaded, the process survives, and
# the window shows the Flutter-rendered first screen (a screenshot with many
# colours). <command> may be a launcher (a symlink, an AppImage) that starts
# home_deck as a child, so the process checked is whichever one in the tree
# runs the home_deck binary. Needs xdotool, ps and ImageMagick (import,
# identify).
set -u

cmd="${1:?usage: smoke_linux.sh <command> [screenshot.png]}"
tmp="$(mktemp -d)"
shot="${2:-$tmp/home_deck.png}"
log="$tmp/app.log"

"$cmd" > "$log" 2>&1 &
pid=$!

# The process running the home_deck binary: $pid or one of its descendants.
app_pid() {
  local p queue=("$pid")
  while [ "${#queue[@]}" -gt 0 ]; do
    p="${queue[0]}"
    queue=("${queue[@]:1}")
    case "$(readlink "/proc/$p/exe" 2> /dev/null)" in
      */home_deck) echo "$p"; return 0 ;;
    esac
    # shellcheck disable=SC2207
    queue+=($(ps -o pid= --ppid "$p"))
  done
  return 1
}

for i in $(seq 1 90); do
  if xdotool search --name 'home_deck|HomeDeck' > /dev/null 2>&1; then
    echo "window is up after ${i}s"
    sleep 10
    kill -0 "$pid" || { echo "$cmd died after showing its window"; cat "$log"; exit 1; }
    app="$(app_pid)" || { echo "no process runs home_deck"; cat "$log"; exit 1; }
    import -window root "$shot"
    colours="$(identify -format %k "$shot")"
    echo "screenshot has $colours distinct colours"
    echo "--- mapped libraries (pid $app)"
    awk '{print $6}' "/proc/$app/maps" | grep -E 'libapp\.so|libmpv|libflutter_linux_gtk|libepoxy' | sort -u
    grep -q 'libapp\.so' "/proc/$app/maps" || { echo "libapp.so is not mapped"; cat "$log"; exit 1; }
    grep -q 'libmpv' "/proc/$app/maps" || { echo "libmpv is not mapped"; cat "$log"; exit 1; }
    kill "$pid"
    echo "--- app output"
    cat "$log"
    [ "$colours" -ge 20 ] || { echo "window looks blank"; exit 1; }
    exit 0
  fi
  kill -0 "$pid" 2> /dev/null || { echo "$cmd exited early"; cat "$log"; exit 1; }
  sleep 1
done
echo "no window after 90s"
cat "$log"
exit 1
