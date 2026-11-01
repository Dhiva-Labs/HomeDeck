# Flatpak

The `flatpak` job in `.github/workflows/desktop.yml` builds
`homedeck-<version>-<x86_64|aarch64>.flatpak` on the GNOME 51 runtime, then
installs that bundle in the Flatpak builder container and runs it
(`test-bundle.sh`): every ELF file must find its libraries inside the sandbox,
the bundled `parecord` and `pactl` must start from `PATH` (`check-tools.sh`),
and the HomeDeck window must come up under Xvfb.

The manifest does not compile anything. It takes the installed tree CI builds
from the release tarball (`packaging/linux-distros/make-tree.sh`), after
`packaging/linux-distros/bundle-libmpv.sh` added libmpv with its dependency
chain (ffmpeg, libass, libplacebo, ...) from Ubuntu 24.04 under
`usr/lib/homedeck/lib/` and `parecord`/`pactl` (which the `record` plugin runs
for the wake word) under `usr/lib/homedeck/tools/bin/`, with each copied
package's copyright file and exact version in `lib/mpv/licenses/`. The runtime's
own ffmpeg has other sonames than Ubuntu's libmpv, so the chain comes with it.

Install a bundle from a release (the GNOME runtime comes from Flathub):

```sh
flatpak remote-add --user --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak install --user ./homedeck-1.1.0-x86_64.flatpak
flatpak run com.dhivalabs.home_deck
```

Permissions: Wayland/X11, the GPU, the network (Home Assistant, MQTT, Hue,
cameras and the LAN scan) and PulseAudio (camera audio and the wake word's
microphone). The runtime has no `ip` command, so the LAN scan's gateway lookup
falls back to `/proc/net/arp` there.

## A Flathub submission would differ

- Flathub does not build from CI artifacts or take libraries copied from
  another distribution. The `tree` source becomes the release tarball
  (`type: archive`), libmpv is built from source against the runtime's
  ffmpeg, and pulseaudio-utils from source.
- Flathub asks for a free-software or redistributable licence in the
  metainfo; the repository has none.
- `flatpak-builder-lint` must pass on the manifest and the metainfo
  (screenshots, release notes, a brand colour).
