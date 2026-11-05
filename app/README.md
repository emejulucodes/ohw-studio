# OHW Studio

A native macOS (SwiftUI + CoreBluetooth) companion app for the OHW-11 smartwatch, built on the
protocol reverse-engineered in `../docs/FINDINGS.md`. No Python, no CO FIT needed.

## Run
```bash
./scripts/build_app.sh          # builds build/OHW Studio.app (release, ad-hoc signed)
open "build/OHW Studio.app"
```
Allow Bluetooth on first launch, and Automation (Spotify/Music) the first time a music action runs.
The watch accepts one app at a time: turn off the iPhone's Bluetooth (or close CO FIT) while using it,
and stop `tools/remote.py` if it is running.

## Features
| Page | What it does |
|---|---|
| Today | Live mirror of the installed Composer face (real time + today's data), activity rings vs. goals, heart / battery health / next alarm / workout tiles, world-clock and stock strips, now playing, weather |
| Health | Steps/energy/distance, live heart-rate measurement, activity bar chart, heart-rate and sleep charts (Swift Charts) |
| Face Composer | Layer-based face editor: drag, resize, rotate and snap layers on a live canvas; live layers (time, date, weekday, month, AM/PM, steps, heart, kcal, distance, analog hands, β battery/seconds) and artwork (text, SF Symbols, shapes, frosted glass, gradient rings, dials incl. screen-following tracks, glows, images, photo backgrounds); gradients, outlines, shadows/glow, blend modes, any installed font; 7 templates + 6 widgets; undo/redo, autosaved designs, .ohwface import/export, size estimate and one-click install |
| Watch Faces | 4 quick designs (Studio, Portrait, Chrono, Pulse), accent colour, photo drop + crop, live preview, Bluetooth install with progress, PNG export |
| Assistant | Wrist voice assistant: listens through the watch mic (Bluetooth hands-free), on-device speech-to-text, built-in commands (steps, heart, battery, weather, time, alarms, workouts, music, stocks, find watch) and Claude (claude-opus-5-5, key in Keychain) for everything else; answers on the watch speaker and screen; trigger from a mapped watch button, the orb, ⌥Space or ⌘K |
| Contacts | Up to 20 people on the watch: pick from the macOS Contacts app (search, choose which number), add by hand, reorder; sync linked contacts or a Contacts group automatically; send replaces the watch's list |
| Workout | Start outdoor run, treadmill, cycling or climbing on the watch from the Mac; speed and cadence control, live pace/distance/calories, heart rate streamed from the watch, history |
| Wellness | Hidden cycle tracking (period, fertile window, ovulation, watch reminders), move / water / hand-wash reminders, automatic heart-rate and SpO₂ monitoring windows, raise-to-wake, Do Not Disturb, body profile, emergency SOS contact, calorie/distance/sleep goals, 12/24 h, units, vibration |
| Alarms | Up to 10 vibrating alarms with repeat days and labels |
| World Clock | Cities for the watch's World Clock app (DST-aware) |
| Stocks | Live stock/crypto quotes (Yahoo Finance) pushed to the watch's Stocks app every 5 min |
| Internals | The watch's firmware log and raw settings registers, exportable |
| Developer | Behind a warning gate: rename watch, shut down, calls/audio Bluetooth on/off, time travel, time-zone register, watch language, °C/°F, date format, anti-lost; factory self-test (hardware report, live accelerometer, motor, buttons, touch, sensors); command lab for all 318 protocol keys with dangerous-key lock; key scanner; decoded capability flags; notification-icon lab, fake calls, simulated watch buttons; link stats, protocol log export, raw .bin face upload |
| Remote | Map every watch button (music, camera shutter, find phone) to Mac actions: media, volume, screenshot, lock, slides, chime, any Shortcut; live event feed |
| Weather | City search (Open-Meteo), current + 3-day forecast pushed to the watch, auto-refresh, answers the watch's weather requests |
| Messages | Send notifications to the watch, ring it, quick reminder templates |
| Device | Screen timeout, brightness, step goal, clock sync, firmware feature map |
| Console | Every protocol frame, live |
| ⌘K | Command palette: jump to any page or run actions (ring, sync, start a workout…) |
| Menu bar | Battery, steps, heart rate, now playing, quick Ring / Clock / Sync |

Track sync, remote actions and weather run in the background while the app is open (it stays in the
menu bar when the window is closed).

## Layout
- `Protocol.swift` – AB framing, CRC-16/ARC, frame parser, device-info decoder
- `WatchLink.swift` – CoreBluetooth link: scan/connect/handshake, flow-controlled writes, request/collect, watch-command replies, face stream, auto-reconnect
- `FaceKit.swift` – JieLi RLE + image encoders, face container, drawing canvas, glyph sets
- `FaceDesigns.swift` – the four quick face designs
- `ComposerModel.swift`, `ComposerEngine.swift`, `ComposerTemplates.swift`, `ComposerState.swift`, `ComposerView.swift`, `ComposerInspector.swift` – Face Composer (document model, renderer/encoder, templates, editor state, UI)
- `WatchExtras.swift`, `ExtrasViews.swift` – alarms, world clock, stocks, wellness settings, internals
- `DeveloperTools.swift`, `DeveloperViews.swift`, `DeviceInfoSpec.swift` – Developer section (engine, UI, generated key/capability tables)
- `Assistant.swift`, `AssistantView.swift` – voice assistant (audio capture, Speech, commands, Claude Messages API over HTTP)
- `JieLiChip.swift` – JieLi RCSP channel: E1/SAFER+ handshake, chip report, chip clock and tones (Developer › JieLi chip)
- `WatchContacts.swift`, `ContactsView.swift` – contacts on the watch (CONTACT 0x0704 stream, Contacts framework sync)
- `Services.swift` – media bridge (osascript), remote actions, Open-Meteo weather
- `Store.swift` – app state and orchestration
- `Theme.swift`, `Views.swift`, `App.swift` – UI

Headless face test: `.build/debug/OHWStudio --render-faces <dir>` writes each design's `.bin` + preview PNG
(decode with `../tools/face.py render`). `--render-composer <dir>` does the same for the Composer templates.
