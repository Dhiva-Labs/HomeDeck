# HomeDeck Hub

An optional single Go binary that runs on a Raspberry Pi or any always-on PC.
The app works fine without it. The hub adds three things the app cannot do
alone:

1. **Round-the-clock network scanning.** A phone with its screen off isn't
   scanning anything. The hub is, so presence history is real.
2. **Reliable Wake-on-LAN.** The hub is usually on Ethernet, so its magic
   packets reach segments a Wi-Fi panel's broadcast may not.
3. **Camera transcoding.** ffmpeg converts RTSP to MJPEG, which is what makes
   very old devices work at all.

## The point of MJPEG

A 2012 Android phone or an iOS 6 iPad cannot play RTSP, and cannot decode
H.264 in a browser. But every browser ever shipped renders **multipart MJPEG
in a plain `<img>` tag**, with no JavaScript and no video codec.

So the hub's dashboard is deliberately primitive: no framework, no flexbox, no
CSS variables, no `<script>` tag at all, and a `<meta refresh>` so it stays
current even with JavaScript disabled. Wake buttons are plain form POSTs.

One ffmpeg process per camera is shared by every viewer, and it's killed when
the last viewer leaves — ten panels watching the front door cost one transcode,
and an idle wall costs nothing.

## Build and run

```bash
cd hub && go build -o homedeck-hub .
./homedeck-hub
```

Then open `http://<hub-ip>:8477` on any device, however old.

Flags:

| Flag | Default | Meaning |
|---|---|---|
| `-addr` | `:8477` | Listen address |
| `-config` | `homedeck-hub.json` | Camera list, created on first save |
| `-scan-interval` | `2m` | How often to sweep the LAN |
| `-fps` | `5` | Restream frame rate — 5 is plenty for a wall panel |
| `-width` | `640` | Restream width; height follows the aspect ratio |
| `-quality` | `7` | JPEG quality, 2 (best) to 31 (worst) |

Requires `ffmpeg` on `PATH` for camera restreaming. Scanning and Wake-on-LAN
work without it.

## Cross-compiling for a Pi

```bash
GOOS=linux GOARCH=arm64 go build -o homedeck-hub-arm64 .
```

## Running as a service

```ini
# /etc/systemd/system/homedeck-hub.service
[Unit]
Description=HomeDeck Hub
After=network-online.target

[Service]
ExecStart=/opt/homedeck/homedeck-hub
WorkingDirectory=/opt/homedeck
Restart=always

[Install]
WantedBy=multi-user.target
```

## API

| Endpoint | Method | Purpose |
|---|---|---|
| `/api/hosts` | GET | Every host seen on the LAN, with online state |
| `/api/scan` | GET | Trigger an immediate rescan |
| `/api/cameras` | GET, POST | List or add/update a camera |
| `/api/wake?mac=…` | GET, POST | Send a Wake-on-LAN magic packet |
| `/stream/{id}` | GET | MJPEG stream, `multipart/x-mixed-replace` |
| `/snapshot/{id}` | GET | Single JPEG frame, for grid thumbnails |
| `/` | GET | The retro dashboard |

The app's Hub connector polls `/api/hosts` every 30 seconds and, when a hub is
configured, plays cameras through `/stream/{id}` instead of decoding RTSP
locally. Camera credentials then live only on the hub, never in a URL on the
panel.

## Status

**This is the one part of HomeDeck that has not been compiled or run.** There
is no Go toolchain on the machine it was written on, so `go build` was never
executed and none of it has been exercised against a live camera. Treat the
first build as a real review step. The Flutter side that talks to it *is*
tested (`app/test/hub_test.dart`).
