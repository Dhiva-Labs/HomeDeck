#!/usr/bin/env bash
# Runs inside the Flatpak sandbox (test-bundle.sh, SANDBOX_TEST): the
# wake-word recorder (record_linux) runs parecord and pactl from PATH, so the
# bundled copies must be found there and start with their libraries. Actual
# recording needs a sound server, which the CI container does not have.
set -euo pipefail
for t in parecord pactl; do
  command -v "$t"
  "$t" --version
done
