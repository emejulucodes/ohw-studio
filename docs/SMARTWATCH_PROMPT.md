# Prompt: reverse-engineer a smartwatch and build its companion app

A reusable prompt for an AI coding agent (Claude Code or similar), distilled from the OHW-11 / OHW Studio project.
Fill in the `{{…}}` fields, paste everything below the line as the first message, and keep the agent in the
project folder with Bluetooth, a terminal and (ideally) a browser and desktop control available.

| Field | Example |
|---|---|
| `{{WATCH}}` | OHW-11 |
| `{{VENDOR_APP}}` | CO FIT (Android `com.codingiot.co.fit`, iOS id1514529526) |
| `{{HOST}}` | macOS 14+ · SwiftUI + CoreBluetooth |
| `{{TOOLS_LANG}}` | Python 3 + bleak |
| `{{GITHUB}}` | `your-username` (optional, for publishing at the end) |

---

You are reverse-engineering the **{{WATCH}}** smartwatch, which I own, so that it can be used without its vendor
app **{{VENDOR_APP}}**. The goal is a native **{{HOST}}** companion app that does everything the vendor app
does, plus anything hidden that the watch supports. This is interoperability research on my own hardware.
I authorise risky experiments on the watch itself, but follow the safety rules below.

## Working rules

1. **Evidence first.** Every claim about the protocol must come from a capture, the decompiled vendor app, or a
   test on the watch. Mark anything inferred as "inferred" until a hardware test confirms it.
2. **Keep a notebook.** Maintain `docs/FINDINGS.md`: device identity, GATT table, frame format, every key/command
   with its byte layout, what was verified on hardware (with date), what does not work and why. Update it after
   every discovery, not at the end.
3. **Read before write.** Before changing any setting, read and save its current value so you can restore it.
   After a write, read it back.
4. **Ask me to look.** Many effects are only visible on the watch (screens, vibration, sound). When a test
   depends on that, tell me exactly what to watch for and when, then ask what happened. Never report a feature as
   working until I or a read-back confirms it. If a test never ran (e.g. connection failed), say so and rerun it.
5. **Dangerous operations need my explicit OK** each time: firmware/OTA, flash writes or erases, factory reset,
   formatting, shutdown/reboot, rename, unbinding, and anything that replaces a whole list on the watch
   (contacts, alarms, faces). Never send a destructive command automatically, including from a sync loop.
6. **Privacy.** My phone numbers, contacts, photos, location, health data and keys must never appear in commits,
   screenshots, logs you publish or requests to third-party servers. Redact captures before committing. Don't
   send device identifiers (MAC etc.) to vendor servers unless I ask.
7. **Vendor code stays local.** The APK/IPA, decompiled sources and native libraries are for analysis only. Never
   commit or redistribute them. Re-implement what you learn in your own code.
8. **One connection at a time.** Most watches accept a single BLE central. Remind me to turn off my phone's
   Bluetooth (or close the vendor app) before Mac tests, and quit the app before running scripts.
9. **Keep me informed.** Say in a sentence what you're doing during long steps. End each phase with a short
   summary: what works, what doesn't, what's next.

## Phase 1: identify the watch

- Scan BLE and record: advertised name, manufacturer data (company ID), service UUIDs, RSSI.
- Connect and dump the full GATT table (services, characteristics, properties, descriptors).
- Check classic Bluetooth too (`system_profiler SPBluetoothDataType` on macOS): vendor/product ID, firmware,
  profiles (HFP/A2DP/AVRCP/HID mean the watch can be a mic, speaker or remote).
- Map company ID → silicon vendor (e.g. 0x05D6 = JieLi). Recognise common families:
  - Nordic UART `6E400001…` with frames starting `AB` → SMA / "smable3" protocol.
  - `AE00`/`AE01`/`AE02` → JieLi RCSP (auth-gated vendor channel).
  - `FEE7`, `FEEA`, `FF01…` and others → MOYOUNG/Da Fit, FitPro, Realtek, Actions, Bluetrum, Sifli…
  - Check Gadgetbridge's supported-device list and GitHub for an existing protocol write-up first; reuse it with
    credit (and its license) rather than starting from zero.
- Subscribe to all notify characteristics and listen idle; note anything unsolicited.

## Phase 2: get the vendor app's knowledge

- Download the vendor app (APK/XAPK from a mirror; note version). Decompile with JADX into a local, git-ignored
  folder. Extract native libraries from every split APK.
- Find: the BLE connector class, the command/key enum (names → numeric IDs), frame builder/parser, CRC, handshake,
  every entity class with `encode()/decode()` (these give exact byte layouts), stream/file upload code, and the
  device-info parser with its capability flags.
- Search for hidden screens and developer activities (`Developer`, `Factory`, `Test`, `Debug`, `Repair`,
  `StressTest`), server endpoints (firmware, watch faces, weather), and native libs for auth/crypto/image
  encoding. For native code, use a decompiler if available, otherwise `llvm-objdump` plus `.rodata` dumps;
  constants (S-boxes, bias tables, keys) often identify the algorithm on their own.
- Optional but valuable: a phone-side capture (Android btsnoop / iOS PacketLogger) of the vendor app doing each
  feature once, decoded with a small ATT parser.

## Phase 3: crack the protocol

- Write a small client library in {{TOOLS_LANG}} (`tools/<name>.py`): connect, framing, CRC, chunked writes with
  flow control, reassembly of notifications, request/response matching, and the handshake the app performs.
- Confirm with harmless reads first: battery, firmware version, time, device info. Decode the device-info
  capability flags; they tell you what the firmware claims to support.
- Learn the protocol's quirks and write them down. Ones seen before:
  - The watch acks **every** key with an empty reply, even unsupported ones. Only data replies prove support.
  - Fields narrower than they look (steps were 24-bit; a 32-bit read gave 67 million steps).
  - "Busy" errors right after connecting; wait a couple of seconds and retry.
  - Values stored ×1000, little- vs big-endian mixed within one protocol, UTF-8 names cut mid-character.
  - Watch-initiated commands that expect a reply in a specific form.
- Probe systematically: READ every known key and log which return data. Then sweep the whole key space for
  undocumented ones (skip OTA/flash/stream groups). Save raw logs under `research/captures/`.

## Phase 4: unlock vendor channels and hidden features

- If there's an auth-gated channel (e.g. JieLi RCSP), reimplement its handshake from the native library and
  verify it against the watch's own proof before relying on it. Then query what it exposes (target info, system
  info, file browse, flash info) and record what answers "unsupported".
- For every key that returns data but isn't advertised in the capability flags, read the layout from the entity
  class and test it on the watch (with my eyes on it). Hidden features found this way so far: cycle tracking,
  factory test mode, accelerometer readout, host-driven workouts, rename.
- Try the official firmware-update endpoint only with the request the app normally sends. If the vendor offers
  no firmware for the model, say so; don't scrape unverified catalogues or work around server checks.

## Phase 5: build the companion app ({{HOST}})

Native, no Python dependency. Architecture that worked:

- `Protocol` (framing, CRC, parser), `WatchLink` (scan/connect/handshake, flow-controlled writes,
  request/collect with timeouts, stream uploads with retry, auto-reconnect, raw log), `Store` (app state,
  orchestration, refresh on connect), one file per feature area, a shared design system.
- Pages to aim for, gated by what the watch supports:
  - **Today** dashboard (live face mirror, activity rings, tiles) and **Health** (steps, HR, sleep, SpO₂, stress, BP).
  - **Watch faces**: decode the face container and image encoding, then build a layer-based editor (live
    elements drawn by the watch + artwork baked into the background), templates, size estimate, one-click install.
  - **Notifications/messages**, **weather** push, **music/now playing**, **find watch**, **remote** (watch buttons →
    computer actions).
  - **Alarms, world clock, stocks, contacts** (with sync from the OS address book; never auto-send an empty list).
  - **Wellness**: reminders, monitoring schedules, raise-to-wake, DND, body profile, SOS, goals, hidden features.
  - **Workouts** started from the computer if the watch has a host-driven sport mode.
  - **Voice assistant** if the watch is a Bluetooth audio device: its mic via HFP, on-device speech-to-text,
    built-in commands, an LLM fallback (key in the Keychain), answers on the watch speaker and screen.
  - **Internals / Console**: firmware log, raw registers, every frame live.
  - **Developer** section behind a warning gate: rename, shutdown, time travel, language, factory self-test,
    command lab for every key with a lock on dangerous ones, key scanner, capability flags, vendor-chip tab.
  - Command palette and menu-bar extra.
- Add all permission strings (Bluetooth, Contacts, Microphone, Speech, Automation) to the app's Info.plist.
- After each feature: build, install, open it, check it in the UI (desktop control/screenshots), and confirm on
  the watch.

## Phase 6: verify and harden

- Re-test every feature on hardware after refactors. Keep a "works / doesn't work on this firmware" table.
- Guard against data loss: sync code must not wipe lists on a failed read; destructive actions need confirmation.
- Build from a fresh clone; flag slow Swift type-checking (`-warn-long-expression-type-checking`) so CI with an
  older compiler passes.

## Phase 7: publish (only when I ask)

- Organise: `app/`, `tools/` (+ `requirements.txt`), `docs/` (FINDINGS, images), `research/` (redacted captures),
  `reference/` (third-party docs with their licenses), `.gitignore` excluding vendor binaries, decompiled code,
  build output, virtualenvs and personal media.
- Scan for secrets and personal data before the first commit. Commit feature by feature with clear messages,
  using my name and email. Add attribution or co-author lines only if I want them.
- README: what it is, features, install (unsigned-app instructions), build from source, how the protocols work,
  layout, tools, status table, disclaimer, license. Add screenshots with personal content blurred or cropped.
- Release: build a versioned zip of the app, attach it with notes and a SHA-256, add CI that builds the app and
  checks the tools. Ask me public vs private before creating the repo.

## Deliverables

1. `docs/FINDINGS.md`: the complete, verified protocol notebook.
2. `tools/`: the client library, probes, sweeps, face builder and single-feature tests.
3. The native app, installed and working against my watch.
4. A final report: what works, what's hidden and now unlocked, what's impossible on this firmware and why, and
   sensible next steps.
