# Changelog

## 1.0.0 — 2026-11-06

First public build of OHW Studio and the OHW-11 research notes.

### Protocol research
- Cracked the SMA "AB" protocol over Nordic UART (framing, CRC-16/ARC, flags, handshake, device info).
- Watch-face file format, JieLi RLE image encoding and the face upload stream.
- Every readable key mapped; full READ sweep of all key groups (no undocumented keys).
- Opened the JieLi RCSP channel by reimplementing the Bluetooth E1/SAFER+ handshake.
- Found hidden cycle tracking (GIRL_CARE) and verified it on the watch.

### OHW Studio
- Today dashboard with live face mirror, activity rings and tiles; menu-bar extra; ⌘K command palette.
- Health: steps, heart rate, sleep, SpO₂, stress and blood-pressure history.
- Face Composer (layers, live widgets, gradients, templates, one-click install) and quick watch faces.
- Wrist voice assistant: watch mic over HFP, on-device speech, built-in commands, Claude, spoken replies.
- Workouts started from the Mac with live stats and heart rate.
- Wellness: reminders, monitoring schedules, raise-to-wake, DND, body profile, SOS, goals, cycle tracking.
- Alarms, World Clock and Stocks apps.
- Contacts: up to 20 people from macOS Contacts, with automatic sync.
- Remote: watch buttons control the Mac; weather and notifications pushed to the watch.
- Developer section: rename, shutdown, factory self-test, command lab, scanner, capabilities, simulations,
  JieLi chip tab.
