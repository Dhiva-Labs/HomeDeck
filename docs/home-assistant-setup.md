# Connecting HomeDeck to Home Assistant

HomeDeck works without Home Assistant — it finds network devices and cameras on
its own. Home Assistant adds everything it already manages: lights, switches,
climate, sensors, scenes and its own cameras.

## If you already run Home Assistant

1. In Home Assistant, click your user name (bottom left) → **Security** tab.
2. Scroll to **Long-lived access tokens** → **Create token**. Name it
   `HomeDeck`. Copy the token — Home Assistant shows it exactly once.
3. In HomeDeck: **Settings → Home Assistant**.
4. Tap the search icon in the Address field. HomeDeck looks for Home Assistant
   over mDNS and fills the address in. If nothing is found, type it manually —
   usually `http://homeassistant.local:8123`, or the IP if `.local` names don't
   resolve on your network.
5. Paste the token, tap **Test**, then **Save & connect**.

Your entities appear on the Devices tab within a second or two. Assign them to
rooms and they show up grouped on the dashboard.

## If you don't run Home Assistant yet

You only need it if you want to control smart devices HomeDeck can't reach
directly. It's worth it once you have more than a couple of brands, because
each vendor otherwise wants its own app.

Two reasonable installs:

- **Raspberry Pi (recommended).** Flash **Home Assistant OS** with the
  Raspberry Pi Imager — it appears under "Other specific-purpose OS". A Pi 4
  with 2 GB is plenty. It boots straight into Home Assistant at
  `http://homeassistant.local:8123`.
- **An old PC you leave on.** Run it in Docker:

  ```bash
  docker run -d --name homeassistant --restart unless-stopped \
    --network host -v ~/homeassistant:/config \
    ghcr.io/home-assistant/home-assistant:stable
  ```

  `--network host` matters: without it Home Assistant can't auto-discover
  devices on your LAN.

Once it's running, open it in a browser, create your account, and follow the
steps above.

## What HomeDeck maps

| Home Assistant domain | Shown as | Controls |
|---|---|---|
| `light` | Light | On/off, plus a dim slider when the light reports brightness |
| `switch`, `input_boolean`, `fan`, `siren`, `automation` | Switch | On/off |
| `cover` | Switch | Open/close |
| `scene`, `script` | Scene | Activate |
| `sensor`, `binary_sensor` | Sensor | Value with its unit |
| `climate`, `water_heater` | Climate | Current temperature, target |
| `media_player` | Media | On/off, current title |
| `camera` | Camera | Snapshot thumbnail + live view |

Everything else — `update`, `device_tracker`, `person`, `sun`, diagnostics — is
deliberately skipped so the dashboard stays a control panel rather than an
entity dump. If you want one of those visible, it's a one-line addition to
`kindForDomain` in `app/lib/connectors/ha/ha_connector.dart`.

## Cameras

Home Assistant cameras appear on the Cameras tab next to any camera you added
directly, with no extra setup. HomeDeck uses the signed `entity_picture` URL
Home Assistant provides, so snapshots and streams load without needing to send
an auth header.

## Troubleshooting

**"Token rejected"** — the token was mistyped or has been revoked. Tokens are
long; paste rather than type. Create a fresh one if unsure.

**"Reached the server, but no Home Assistant API at that address"** — usually a
wrong port. Home Assistant listens on 8123 unless you put it behind a reverse
proxy.

**"No response"** — the address isn't reachable from this device. Check they're
on the same network, and try the IP address instead of `homeassistant.local`.
Some Android devices and most old ones don't resolve `.local` names.

**Connected, then drops repeatedly** — expected during a Home Assistant restart
or update. HomeDeck retries every 10 seconds on its own. A wrong *token*, by
contrast, fails permanently rather than retrying, so it's obvious which problem
you have.
