# HomeDeck Assistant — product plan

**Say it, and the house does it. No cloud, no account, no API key.**

HomeDeck already normalizes every device — Home Assistant entities, MQTT
gadgets, ONVIF cameras, bare network hosts — into one `Device` model behind one
action pipeline. The assistant adds a voice front end to that pipeline: a
custom wake word ("Hey Jarvis", or whatever you train), on-device speech
recognition, and a rule-based command grammar that resolves speech to a
`Device` plus a `DeviceAction` and hands it to `ConnectorsService.invoke` —
the same call a tap on a tile makes today. Everything runs on the panel
itself, offline, which is the whole point: a wall-mounted phone that answers
you even when the internet is down, and never sends a syllable of audio
anywhere.

Fixed decisions, not up for debate in implementation:

1. This extends home_deck. It is not a new app.
2. Two wake word engines ship behind one interface — Picovoice Porcupine and
   openWakeWord — switchable in Settings.
3. Understanding is a pure on-device rule grammar. No LLM, no cloud NLU, no
   API key, ever. If the network cable is cut, voice control still works.

## The platform reality matrix

The ask was "connect Google Home, Amazon, etc. all together." These
ecosystems are not symmetric, and this section is the honest version. The
governing rule: **a platform is only reachable if it publishes an API that
lets a third-party app control a *user's* devices.** Most publish the
opposite — an API for device makers to put devices *into* their ecosystem.

| Platform | Third-party control possible? | API | Registration / approval | Practical verdict |
|---|---|---|---|---|
| **Google Home** | **Yes, on Android only** | [Home APIs for Android](https://developers.home.google.com/apis) (`com.google.android.gms.home`, Play services home module): Device & Structure APIs, Commissioning, Automation. OAuth consent per structure, [per-device consent for locks/cameras](https://developers.home.google.com/apis/android/permissions) | None to develop and test (up to **100 test users**). Public release requires [Home Developer Console](https://developers.home.google.com/apis/android/sdk) registration + brand verification; only console-approved device types are controllable. [Not every device type is exposed](https://developers.home.google.com/apis/android/device) | **Build it.** Real, supported, designed for exactly this. Android only — the Linux desktop build gets nothing. Ship as a `googlehome` connector |
| **Amazon Alexa** | **No.** | There is no public API for a third-party app to control a user's Alexa devices. The [Smart Home Skill API](https://developer.amazon.com/en-US/docs/alexa/smarthome/understand-the-smart-home-skill-api.html) is for *device makers* exposing their devices **to** Alexa. [AVS](https://developer.amazon.com/en-US/blogs/alexa/device-makers/2019/12/alexa-smart-home-controls-now-available-via-alexa-voice-service-api) is for *embedding Alexa* into your product. Neither is "control my Alexa stuff from my app" | n/a | **Cannot be built. There will be no "Alexa login" in HomeDeck.** The only route is the [unofficial API](https://github.com/alandtse/alexa_media_player) that mimics the Alexa app, which Amazon can (and does) break without notice — we will not ship a connector on it. Consolation: devices *behind* Alexa are almost always also on Matter, a vendor cloud, or Home Assistant, all of which we can reach |
| **Matter / Thread** | **Yes, via an ecosystem — not standalone** | On Android, the [Home Mobile SDK](https://developers.home.google.com/matter/apis/home) commissions Matter devices via the [Play services home module](https://developers.home.google.com/matter/apis/home/commissioning); control then flows through the Google Home APIs above. Alternative: Home Assistant's Matter server, which turns Matter devices into plain HA entities | Same Home Developer Console story as Google Home for the Google path; nothing for the HA path | **Reach Matter through Google Home APIs or through Home Assistant.** Embedding a full Matter controller + Thread border-router awareness inside a Flutter app is a project bigger than HomeDeck itself. Out of scope as a native connector |
| **SmartThings** | Yes, but hostile since Dec 2024 | [REST API](https://developer.smartthings.com/docs/getting-started/authorization-and-permissions) with OAuth or Personal Access Tokens | [PATs created after 30 Dec 2024 expire in 24 hours](https://community.home-assistant.io/t/smartthings-pat-changes/821584) with tighter rate limits; the sanctioned path is an OAuth `authorization_code` flow, which requires registering a SmartThings developer app | **Don't build a direct connector.** A token the user must recreate daily is not a product. Home Assistant's SmartThings integration already handles the OAuth dance — route through HA |
| **Tuya / Smart Life** | Yes, but on a metered cloud | [Tuya IoT Core / Cloud Development](https://developer.tuya.com/en/docs/iot/membership-service?id=K9m8k45jwvg9j) OpenAPI, per-user developer project | Every user must create a Tuya developer account and cloud project; the free [IoT Core trial expires](https://support.tuya.com/en/help/_detail/Kc3n6kr7kllhc) and needs [manual extension or payment](https://github.com/tuya/tuya-home-assistant/issues/804), which regularly strands integrations | **Don't build a direct connector.** A connector that dies when a trial subscription lapses violates the "no account, no API key" promise. Route through HA (official Tuya integration, or `localtuya` for cloud-free control after a one-time key extraction) |
| **Philips Hue** | **Yes, fully local** | [CLIP v2 local API](https://developers.meethue.com/new-hue-api/) on the bridge: HTTPS on the LAN, application key minted by pressing the physical link button. A separate cloud [Remote API](https://developers.meethue.com/new-hue-api/) exists but is not needed on the same network | Free developer account for docs only; nothing required in the product | **Build it.** Best-behaved platform on this list — local, documented, stable. mDNS discovery fits the existing netscan machinery. Ship as a `hue` connector |
| **Home Assistant** | **Yes — already working** | REST + WebSocket, long-lived access token. Existing `ha` connector | None | **The universal bridge.** Anything HA can integrate — SmartThings, Tuya, Matter, Thread, Zigbee, Z-Wave, and 2000+ others — is already a HomeDeck device. Every platform we refuse to connect directly gets a documented "via Home Assistant" recipe instead |

The strategy that falls out: **voice controls what the registry holds; the
registry grows through connectors that are actually buildable.** Direct
connectors for Google Home (Android) and Hue (local). Everything else through
Home Assistant, with honest docs saying so. No connector whose auth breaks
every 24 hours, and no connector built on an API that officially does not
exist.

## The voice pipeline

Four stages, each behind an interface, all on-device:

```
mic ──► WakeWordEngine ──► SpeechRecognizer ──► CommandGrammar ──► Executor
        (Porcupine or      (streaming STT,      (rules → intent +   (DeviceRegistry
         openWakeWord)      grammar-biased)      device query)       lookup →
                                                                     ConnectorsService.invoke)
```

- **WakeWordEngine** — `start/stop`, emits a detection event. Two
  implementations:
  - *openWakeWord* (default): Apache-2.0, runs as a TFLite/ONNX model,
    [ships pre-trained "Hey Jarvis"](https://github.com/dscripka/openWakeWord),
    and anyone can [train a custom phrase from synthetic speech](https://openwakeword.com/train)
    — no vendor account.
  - *Porcupine*: better detection quality, but requires a Picovoice
    AccessKey, and on the [free tier custom wake word models are
    personal-use with 30-day expiry](https://picovoice.ai/docs/faq/porcupine/).
    Ships as bring-your-own-AccessKey; Settings says so plainly.
- **SpeechRecognizer** — streaming on-device STT, starts on wake, stops on
  end-of-speech. Primary candidate: [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx)
  (offline, streaming, has official Dart bindings). Fallback candidate:
  [Vosk](https://alphacephei.com/vosk/) (~50 MB models, runtime-restrictable
  vocabulary). Whichever lands, the recognizer is biased toward the command
  grammar's vocabulary plus the registry's device, room, and scene names —
  a closed vocabulary is what makes small models accurate.
- **CommandGrammar** — deterministic rules (see command surface below).
  Output is an intent: `{action, target query, args}`. Pure Dart, unit-tested
  against a corpus of utterances, no model.
- **Executor** — resolves the target query against `DeviceRegistry`
  (normalized name match, aliases, room + kind filters), maps intent to
  `DeviceAction`, calls `ConnectorsService.invoke` per matched device.

Nothing in the existing architecture changes. The assistant is a consumer of
the registry and the action router, exactly like the dashboard is.

Two registry additions (extensions, not redesigns):

- **Aliases** — a device override gains optional "also answers to" names
  ("telly" for the living room TV). Same override mechanism as rename.
- **Zones** — a named group of rooms ("downstairs" = kitchen + hall +
  living room), stored alongside rooms, editable where rooms are. This is
  what makes "all the lights downstairs" resolvable.

## UX flows

### First run

Voice is off until set up. A "Voice" section in Settings (plus a one-time
dashboard hint) walks through:

1. **Mic permission** — with the sentence "audio never leaves this device"
   right on the permission screen, because it's true.
2. **Engine** — openWakeWord preselected. Choosing Porcupine asks for the
   AccessKey and links to where to get one.
3. **Wake word** — pick a bundled phrase ("Hey Jarvis" default) or import a
   trained model file (`.tflite`/`.onnx` for openWakeWord, `.ppn` for
   Porcupine). The screen links to the openWakeWord training page for
   custom phrases; training happens off-device, once, and produces a file.
4. **Test** — say the phrase three times; the screen shows detections and a
   sensitivity slider. Old-hardware note appears here if performance mode
   is active (see limitations).
5. **This panel's room** (optional) — assign the panel to a room so "turn
   off the lights in here" works.

### Idle listening

- Wake word engine runs continuously on the mic; nothing is recorded,
  nothing is transcribed, the rolling audio buffer is discarded on the fly.
- A small mic glyph in the corner shows state: listening (idle), off, or
  actively capturing a command.
- Overnight dimming and wakelock behavior are unchanged; listening
  continues while the screen is dim.

### Wake → listen → confirm → act

1. Wake word fires: chime (optional), mic glyph goes active, a caption bar
   appears at the bottom of whatever screen is showing.
2. Live transcription streams into the caption bar. End-of-speech is
   silence-based (~1 s) with an 8 s cap.
3. Grammar parses; executor resolves and invokes.
4. Confirmation is visual always (caption bar shows "Kitchen light off",
   affected tiles flash their new state) and spoken optionally (system TTS,
   off / short / verbose in Settings). Then the bar dismisses.

Total wake-to-action target: under 2 seconds on mid hardware.

### Failure and ambiguity

| Case | Behavior |
|---|---|
| Didn't parse | "Didn't catch that" in the caption bar with the transcription shown, so the user can see *what* was heard. One retry listen. No endless loop |
| No matching device | "No device called 'porch light'." Bar offers the closest name matches as tappable chips |
| Ambiguous match ("kitchen light" matches two) | Asks "Which kitchen light?", speaks the choices if TTS is on, lists them as chips, and listens once for an answer ("the counter one" / "both"). Tap or voice both resolve it |
| Device offline | "Front hall lamp looks offline." No silent failure |
| Connector error | Same message a failed tap shows today, surfaced in the bar |
| "all" matching a big set (>10 devices) | Confirms once: "Turn off 14 lights?" — yes/no by voice or tap |

Every failure path ends within one round trip. This is a wall panel, not a
conversation partner.

### Privacy and mic-off

- **Mic-off is one tap** on the mic glyph, and it actually stops the audio
  stream — not just detection. State survives restart.
- Optional scheduled mic-off (e.g. night hours), reusing the overnight
  dimming schedule UI.
- Android's mic-in-use indicator will be on whenever listening is on; the
  docs say so instead of pretending otherwise.
- No audio, transcription, or command history leaves the device. Command
  history (text only) is kept locally for a "recent commands" list in
  Settings and can be cleared or disabled.

## Command surface

The grammar is rules over a closed vocabulary. Placeholders: `<device>` any
registry name or alias, `<room>` any room, `<zone>` any zone, `<scene>` any
scene-kind device, `<n>` a number. Articles ("the", "my") and politeness
("please") are stripped before matching. Room scoping works in three forms
and all are equivalent: "the kitchen light", "the light in the kitchen",
"...in here" (panel's assigned room).

### Lights, switches, outlets (`toggle`, `brightness`, `colorTemp`)

| Utterance patterns | DeviceAction |
|---|---|
| turn on/off `<device>` · switch on/off `<device>` · `<device>` on/off | `turn_on` / `turn_off` |
| toggle `<device>` | `toggle` |
| dim / brighten `<device>` | `set_brightness` (step ±20%) |
| set `<device>` [brightness] to `<n>` [percent] · `<device>` to `<n>` | `set_brightness` |
| make `<device>` warmer/cooler · set `<device>` to warm white / cool white | `set_color_temp` |
| turn on/off the lights [in `<room>`/`<zone>`/here] | fan-out to kind=light in scope |
| turn off all the lights · lights out [everywhere] | fan-out to every kind=light |
| turn off everything in `<room>`/`<zone>` | fan-out to all toggleable kinds in scope |

Multi-device fan-out ("all the lights downstairs") resolves the scope to a
device set and invokes each device's own connector — mixed HA + MQTT + Hue
sets work because routing is per-device, as it already is.

### Climate (`setValue`)

| Utterance patterns | DeviceAction |
|---|---|
| set `<device>`/the thermostat [in `<room>`] to `<n>` [degrees] | `set_temperature` |
| make it warmer/cooler [in `<room>`] | `set_temperature` (step ±1°) |
| turn on/off the heating / the AC [in `<room>`] | `turn_on` / `turn_off` on kind=climate |

### Media, speakers, TVs

| Utterance patterns | DeviceAction |
|---|---|
| pause / resume / play [on] `<device>` | `media_pause` / `media_play` |
| next / previous [track] on `<device>` | `media_next` / `media_previous` |
| volume up/down on `<device>` · set `<device>` volume to `<n>` | `set_volume` |
| mute / unmute `<device>` | `mute` / `unmute` |
| turn on/off the TV [in `<room>`] | `turn_on` / `turn_off` |

### Scenes

| Utterance patterns | DeviceAction |
|---|---|
| activate / run / start `<scene>` · `<scene>` scene | `activate` on kind=scene |
| good night · movie time (aliases users attach to scenes) | same |

### Cameras (panel-local actions)

| Utterance patterns | Behavior |
|---|---|
| show [me] the `<device>` [camera] · what's on the `<device>` camera | opens fullscreen camera view on this panel |
| close the camera / go back | returns to previous screen |

### Network devices (`wake`, `ping`)

| Utterance patterns | DeviceAction |
|---|---|
| wake [up] the `<device>` · turn on the `<device>` (kind=computer/nas) | `wake` (Wake-on-LAN) |
| is [the] `<device>` online / up? | `ping`, answer in caption bar / TTS |

### Status queries (read registry state, no action)

| Utterance patterns | Answer from |
|---|---|
| is the `<device>` on? | `state['on']` |
| what's the temperature [in `<room>`]? | kind=sensor/climate `state['value']` in scope |
| are any lights on [in `<room>`/`<zone>`]? | scoped scan of kind=light |

The grammar maps each action to a required `DeviceCapability`; a matched
device without the capability gets a plain "Desk fan can't do brightness"
instead of a silent no-op. The full pattern corpus lives with the grammar's
unit tests and is the contract — if an utterance is in the corpus, it must
parse, on every commit.

## Milestones

### M1 — hears you, and one light obeys

The thinnest end-to-end slice: openWakeWord with the bundled "Hey Jarvis"
model, streaming on-device STT, grammar covering only on/off/toggle for
lights, switches and outlets with room scoping, executor wired to
`ConnectorsService.invoke`, caption bar with visual confirmation, mic-off
toggle. Android only. Porcupine, TTS, and everything else is absent.

**Done when:** on a wall panel in airplane mode with Wi-Fi only (no
internet), "Hey Jarvis, turn off the kitchen light" turns off a Home
Assistant light and an MQTT light, wake-to-action under 3 s on the reference
mid-range phone, and the grammar corpus for the M1 patterns passes in
`flutter test`.

### M2 — the full command surface

Every pattern table above: climate, media, scenes, cameras, WoL, status
queries, zones, "all"-fan-out with the >10 confirmation, aliases,
ambiguity chips + voice disambiguation, optional TTS confirmations, recent
commands list, scheduled mic-off. Linux desktop gets the pipeline too.

**Done when:** the full utterance corpus passes; "turn off all the lights
downstairs" acts on a mixed HA+MQTT set; "which kitchen light?" round trip
works by voice and by tap; every failure case in the table above produces
its specified message.

### M3 — your own wake word, your choice of engine

Porcupine as the second engine behind the same interface (AccessKey entry,
`.ppn` import), custom model import for openWakeWord, the guided first-run
flow with detection test and sensitivity slider, per-panel room assignment
("in here"), performance-mode integration (see limitations).

**Done when:** a user-trained "Hey Computer" model imported as a file wakes
the panel; switching engines in Settings requires no restart; the setup flow
completes on a clean install without touching docs.

### M4 — reach: Hue direct, Google Home direct, bridges documented

The `hue` connector (mDNS bridge discovery, link-button pairing, CLIP v2
lights/scenes) and the `googlehome` connector (Android-only: Home APIs
permission flow, device list into the registry, on/off/brightness at
minimum, honest in-app note about the 100-test-user cap until console
verification). Plus `docs/bridging.md`: the tested recipes for reaching
SmartThings, Tuya, and Matter through Home Assistant, and the Alexa
explanation this plan's matrix gives, in user-facing words.

**Done when:** a Hue bulb and a Google Home-managed device each appear in
the registry and respond to "Hey Jarvis, turn off ..." like any other
device; the Google connector degrades gracefully on Linux (absent, with a
one-line explanation in Settings); the bridge recipes have each been run
once for real.

## Honest limitations (for the README)

- **No Alexa.** Amazon publishes no API that lets an app like this control
  your Alexa devices, so HomeDeck will never have an "Alexa login". If a
  device is Alexa-*compatible*, it almost certainly also speaks Matter, a
  vendor API, or Home Assistant — connect it that way and voice works.
- **It's a command grammar, not a conversation.** "Turn off the kitchen
  light" works. "It's too bright in here" does not. There is no LLM by
  design; the supported phrasings are documented and finite. It will never
  answer "what's the weather".
- **English only at first.** The grammar and STT models are per-language;
  the interfaces allow more languages later, but only English is in scope
  for M1–M4.
- **Wake words are probabilistic.** Expect occasional missed wakes and rare
  false wakes; the sensitivity slider trades one for the other. Porcupine
  detects better but needs a Picovoice AccessKey, and its free tier limits
  custom wake words to personal use with 30-day model expiry.
- **The oldest panels may not listen.** Always-on wake word + streaming STT
  costs real CPU. On devices where performance mode already strips effects,
  the assistant offers push-to-talk (tap the mic glyph, then speak — no
  wake word) instead of always-on listening, and says why.
- **Google Home control is Android-only** and, until the app is registered
  and verified in Google's Home Developer Console, limited to 100 test
  users. The Linux build controls everything else, just not Google Home
  devices.
- **Voice reaches what HomeDeck reaches.** The assistant adds no devices by
  itself; if it isn't in the registry, it can't be commanded.

## Sources

- Google Home APIs: [overview](https://developers.home.google.com/apis) · [Android SDK](https://developers.home.google.com/apis/android/sdk) · [permissions & consent](https://developers.home.google.com/apis/android/permissions) · [device access limits](https://developers.home.google.com/apis/android/device)
- Matter on Android: [Home Mobile SDK](https://developers.home.google.com/matter/apis/home) · [commissioning](https://developers.home.google.com/matter/apis/home/commissioning) · [sample third-party ecosystem app](https://github.com/google-home/sample-apps-for-matter-android)
- Alexa: [Smart Home Skill API (device makers)](https://developer.amazon.com/en-US/docs/alexa/smarthome/understand-the-smart-home-skill-api.html) · [Smart Home for AVS (embedding Alexa)](https://developer.amazon.com/en-US/blogs/alexa/device-makers/2019/12/alexa-smart-home-controls-now-available-via-alexa-voice-service-api) · [unofficial API status](https://github.com/alandtse/alexa_media_player)
- SmartThings: [auth docs](https://developer.smartthings.com/docs/getting-started/authorization-and-permissions) · [24-hour PAT change](https://community.home-assistant.io/t/smartthings-pat-changes/821584)
- Tuya: [cloud plan pricing](https://developer.tuya.com/en/docs/iot/membership-service?id=K9m8k45jwvg9j) · [IoT Core trial expiry](https://support.tuya.com/en/help/_detail/Kc3n6kr7kllhc) · [expiry breaking integrations](https://github.com/tuya/tuya-home-assistant/issues/804)
- Philips Hue: [CLIP v2 API](https://developers.meethue.com/new-hue-api/)
- Wake word: [openWakeWord](https://github.com/dscripka/openWakeWord) · [custom training](https://openwakeword.com/train) · [Porcupine docs](https://picovoice.ai/docs/porcupine/) · [Porcupine FAQ / free-tier limits](https://picovoice.ai/docs/faq/porcupine/)
- STT: [sherpa-onnx](https://github.com/k2-fsa/sherpa-onnx) · [Vosk](https://alphacephei.com/vosk/)
