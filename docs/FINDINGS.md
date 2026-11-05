# OHW-11 reverse-engineering notes

## Device identity (observed)
| Field | Value | Source |
|---|---|---|
| Name | OHW-11 | BLE advert + macOS BT |
| MAC (classic/BLE) | C0:0C:D4:B3:F1:8F | system_profiler; also embedded in BLE mfr data |
| Vendor ID / Product ID | 0x05D6 / 0x000A | system_profiler |
| Firmware | 2.4.0 | system_profiler |
| Classic BT profiles | HFP, HID | system_profiler (calls + camera/music remote) |
| BLE mfr data | company 0x05D6: `0200810052c00cd4b3f18f804344c00cd4b3f18f00000000000000` | research/captures/scan_v.txt |
| App | CO FIT (iOS id1514529526), Shenzhen Coding IOT Technology Ltd (深圳叩鼎科技) | App Store |

Inference (not yet confirmed): 0x05D6 is the Bluetooth SIG company ID used by Zhuhai JieLi
Technology; the AE00 service below is JieLi's standard RCSP channel. Chipset is likely a JieLi
AC70x-series watch SoC.

## GATT table (observed, research/captures/gatt.txt)
| Service | Char | Props | Likely role |
|---|---|---|---|
| 6e400001-… Nordic UART | 6e400002 (RX) | write, write-no-rsp | CO FIT command channel (time, alarms, notifications, health sync) |
| | 6e400003 (TX) | notify | watch → app replies/data |
| 0000ae00 JieLi | ae01 | write-no-rsp | RCSP commands (OTA, watch-face/"dial" file transfer) |
| | ae02 | notify | RCSP replies |

## Probes
- Subscribed to both notify chars, idle 8 s: watch sent nothing unsolicited.
- RCSP GET_TARGET_FEATURE (`fedcba c0 03 0005 01 ffffffff ef`) on AE01: **no reply** —
  consistent with JieLi requiring an auth handshake before RCSP commands.

## Protocol CRACKED (2026-11-05): SMA "AB" protocol on Nordic UART
Matches the public reverse-engineering in `re/sma-ref` (bdrtr/dsmart-r18-sma-protocol), same
GATT handles (NUS write 0x0006, ae01 0x0082). Verified live on this watch.

- Frame: `AB | hdr | len BE16 | crc16-ARC BE16 | [BleKey BE16][BleKeyFlag][data]`
  - hdr `0x01` = command, `0x11` = reply. Flags: UPDATE 00, READ 10, CREATE 20, DELETE 30, RESET 40.
- Handshake: `IDENTITY 0x0301 CREATE 284667c2` → watch replies `00`.
- **New finding (fixes the reference's "one big read per session" quirk):** after the handshake
  the watch *sends a command of its own* (hdr 0x01, key 0x0301, 201-byte device info). It
  stops answering until the host replies `ab 11 0003 90f1 0301 00` (hdr 0x11, same key+flag).
  With that reply, any number of reads/writes work in one connection.
- Device info push: `OHW-11 | C0:0C:D4:B3:F1:8F | JL | AM08 | WATCH11_HWZFB_OHW`;
  supported data keys 05ff 0502 0503 0504 050d 0505 050e 0509 050b.
- AB firmware version (0x0204) = 0.0.3 (classic BT reports 2.4.0).

### Verified on hardware
| Feature | Key | Result |
|---|---|---|
| Battery | 0x0203 READ | `64` = 100 % |
| Firmware | 0x0204 READ | `000003` |
| MAC | 0x0205 READ | little-endian, `8ff1b3d40cc0` |
| Notification | 0x0401 UPDATE | acked (cat 127 = app msg, 1 = incoming call) |
| Set time | 0x0201 UPDATE `[yy-2000,mo,d,h,mi,s]` | acked |
| Steps history | 0x0502 READ | 16-byte records, 2000-epoch timestamps (today's buckets) |
| HR history | 0x0503 READ | empty (not worn) |
| **Backlight write** | 0x0208 UPDATE `0a` → read `0a` → restored `05` | ✅ round-trip |

### Settings snapshot (research/captures/settings_read.txt) — decodings marked ? are inferred
| Key | Name | Raw | Meaning |
|---|---|---|---|
| 0207 | STEP_GOAL | 00000fa0 | 4000 steps |
| 0208 | BACK_LIGHT | 05 | 5 s screen timeout |
| 0209 | SEDENTARINESS | 7f 08 00 12 00 78 | ? all days, 08:00–18:00, every 120 min |
| 020a | NO_DISTURB_RANGE | 00 00 17 00 07 00… | ? off, 23:00–07:00 |
| 020b | VIBRATION | 01 | on |
| 020c | GESTURE_WAKE | 01 00 00 00 00 | ? raise-to-wake on, all day |
| 020e | HOUR_SYSTEM | 01 | ? 12/24h flag |
| 020f | LANGUAGE | 01 | ? English |
| 0210 | ALARM | (empty) | no alarms |
| 0211 | UNIT_SET | 00 | metric |
| 021e | DATE_FORMAT | 01 | ? |
| 024f | DEVICE_LANGUAGES | 01 … 0f 01 00 02 04 05 06 08 0a 16 19 1b 1c 24 29 35 | ? current + 15 supported langs |
| 0260 | SCREEN_BRIGHTNESS | 06 | level 6 |
| 0213 | FIND_PHONE | ff | ? |
| 021f/0227/026a/029d | watch-face keys | (empty) | write-only or unsupported on READ |


## Custom watch faces — WORKING (2026-11-05)
Source: CO FIT 2.1.4.6 Android XAPK (sha256 146ab1fd…1328), decompiled with jadx 1.5.6; native
libs disassembled with llvm-objdump. A test face uploaded with `tools/ohw.py face` was accepted
(status 0, 124 912 B in 12.8 s) and **shows on the watch**.

### How the app picks the path (decoded device info, tools/devinfo.py)
platform `JL`, prototype `AM08`, mWatchFaceType 99, IO buffer 1018, mSupportWatchface2 0,
mSupport2DAcceleration 1, JL transport 0.
- WatchFaceType 99 → prototype switch → `AM08` → `DialCustomize410_502Activity`
  (410×502 screen, 260×300 preview, imageFormat 2, X_CENTER 2 / Y_CENTER 16, assets `dial_customize_360`).
- mSupportWatchface2 = 0 → `oldSendStream()` → native `WatchFaceBuilder.build` (libsmawatchface.so).
- 2DAcceleration = 1 → isSupportConvertPng → images through JieLi `BmpConvert`; ignoreBlack 4.
- Upload: AB key `WATCH_FACE 0x0701`, same NUS channel — **no JieLi RCSP/auth needed**.

### Face container (libsmawatchface.so `buildWatchFace`, little-endian)
```
u16 total_images | u8 element_count | u8 image_format(2)
element_count × 20 B: u32 data_off | u16 first_img | u16 w,h,x,y | u8 n_imgs
                      | u8 type|0x80(alpha) | u8 gravity | u8 ignoreBlack | u8 playInterval||bottomOffset | u8 leftOffset
total_images × u32 size
image data, concatenated
```
Element types: 1 preview, 2 background, 3-5 hands, 6-13 year/month/day/hour/min/sec/ampm/weekday,
14-19 step/heart/kcal/distance/battery/bt, 20/21 separators, 22 icon, 23 dynamic bg.
App layout: preview(1, 260×300, grav 0) · background(2, 410×503, grav 9) · ampm(12) · hour(9) ·
minute(10, 10 digit images each) · month(7) · day(8) · weekday(13, 7 images); all grav 9 (left|top).

### Image encoding (libjl_bmp_convert.so `br28_*_to_res`, no-pack = BmpConvert type 3/4)
- type 4 (digits, alpha): pixel = `[A][RGB565 hi][RGB565 lo]`; type 3 (bg/preview): `[RGB565 hi][lo]`.
- Each row RLE'd by `Rle_Encode(unit=3|2, thr=3)`: `0x80|n` + 1 pixel (run of ≥3, n≤127) or
  `n` + n literal pixels (n≤127).
- Output = h × u32 LE `(offset & 0x1FFFFF) | (len << 21)` (offset from buffer start) + rows; padded to 4.

### Upload stream (BaseBleConnector.sendStream / handleData)
- packet: AB `0x0701 UPDATE` data `[slot u8=0][total BE32][offset BE32][≤1018 B]`.
- reply: `[status:4|error:4][total BE32][completed BE32]`; continue from `completed`;
  status≠0 aborts. Errors: 1 try another face, 2 out of space, 4 **device busy** (seen when
  streaming right after connect — wait for the device-info push first), 5 retry.

### Analog hands & health widgets (added 2026-11-05)
- **Hands** (getPointer2, JL branch): types 3/4/5 hour/min/sec, hasAlpha 1, ignoreBlack **1**,
  gravity 9, x,y = screen centre (205,251). Image = **uncompressed** ARGB8565 `[A][565 hi][lo]`,
  row stride padded to 4, only the top 60 % of the 300 px asset (180 rows);
  bottomOffset = h − H/2 (=30) and leftOffset = w/2 locate the pivot. Assets: `time/pointer/pointer/{hour,minute,second}/0-5.png`.
- **Widgets** (getControl2): types 14 step, 15 heart, 16 kcal, 17 distance; 11 value images
  (`value/<color>/0-10.png`, 14×22, JL type 4); gravity 18 (X_CENTER 2 | Y_CENTER 16); x,y = value
  centre = icon centre-x, icon bottom + 1 + h/2. Icons (`control/*/…_0.png`) are baked into the background.
- Tick ring: the app bakes its scale image into the background; face.py draws its own (`--ticks`).
- Status: analog face (hands 0 + ticks + 4 widgets) uploaded, watch replied status 0
  (116 292 B, 11.9 s). **Confirmed on watch**: hands show the correct time and move; widgets show live
  values (0 steps, 84 bpm, 0 kcal, 0.0 distance). The black strip in that test was painted into the
  test background itself; a full-bleed re-test (faces/analog_full.bin) was accepted. Digital+widgets face built, not uploaded.

### Custom-designed faces (tools/pro_face.py) — confirmed on watch 2026-11-05
- Own anti-aliased glyphs (Helvetica Neue, rendered 4× and downsampled) for time/date/AM-PM/widget
  values; each element = one cell size, digits 0-9 (+ "." at index 10 for widget values).
- `pro` layout: black + glow, thin time, 2×2 complication cards (297 KB upload, 25 s).
- `--photo` layout: sharp full-screen photo, bottom gradient, shadowed text (700 KB, 55 s — photos
  RLE poorly; watch accepted it, so the face slot holds at least ~700 KB).

## Watch as a Mac remote — WORKING (2026-11-05, tools/remote.py)
Watch-initiated commands arrive as hdr 0x01 frames; the host must reply (hdr 0x11, same key+flag;
CAMERA echoes its state byte). Observed live:
| Watch action | Frame | Data |
|---|---|---|
| Music play/pause | MUSIC_CONTROL 0x0402 UPDATE | 02 (toggle); 03 next, 04 prev, 05 vol+, 06 vol- (00/01 play/pause in enum) |
| Camera screen open / shutter / close | CAMERA 0x0601 UPDATE | 01 enter, 02 capture, 00 exit |
| Find phone start / stop | FIND_PHONE 0x0213 UPDATE | 01 / 00 |
| Opening music/weather screens | WEATHER_REALTIME 0x0404 **READ** | (watch asks the phone for weather) |
Actions are mapped in `tools/remote_actions.json` (re-read on every event); defaults: Spotify/Music
control via `tools/media.applescript`, system volume ±6, shutter → silent screenshot to Desktop,
find phone → sound + notification. Verified: 5 screenshots saved from shutter presses.

### Watch speaker as a music output — WORKS, but A2DP connects intermittently (2026-11-05)
- Correction: the watch *does* act as a Bluetooth speaker. With A2DP + AVRCP connected, macOS shows
  an "OHW-11" output (2 ch, 44.1 kHz) alongside the 16 kHz HFP microphone.
- The A2DP/AVRCP profiles are not always up: the watch sometimes offers only HFP + HID (then no
  output device). Seen with A2DP while/after the watch's music screen was used. Exact trigger unknown
  (candidate: CLASSIC_BLUETOOTH_STATE 0x0605, supported per device info).
- Device-info mSupportMusicTransfer = 0 refers to copying music files to the watch, not streaming.
- When connected, the watch also becomes the Mac's default mic (16 kHz) — reset in Sound › Input.

### Now-playing on the watch — WORKING (2026-11-05)
- Host → watch: `MUSIC_CONTROL 0x0402 UPDATE [entity u8][attr u8][UTF-8 text]` (AMS-style).
  Entities: 0 player (0 name, 1 playback info, 2 volume), 1 queue, 2 track (0 artist, 1 album, 2 title, 3 duration).
- Subscriptions: `0x0402 READ` → reply `00 02 01 02 | 02 01 02` = player{playback info, volume}, track{title}.
  The watch shows only the title, so remote.py sends "Title - Artist".
- Playback info text = "state,rate,elapsed" (state 0 paused / 1 playing); volume = "0.00"-"1.00".
- remote.py polls Spotify/Music (`tools/nowplaying.applescript`) every 2 s and right after watch
  music presses; confirmed: the title shows and updates when skipping. Needs macOS Automation permission.

## Unknowns / next steps
1. ~~NUS command format~~ — solved (above).
2. ~~Custom watch faces~~ — solved (above). Hands + widgets implemented and confirmed. Open: battery/BT
   icons (18/19), multi-slot picker (DialPickerPopup / WATCHFACE_INDEX).
3. Alarm (0x0210) and weather (0x0404/0x0405) write layouts — now readable in the decompiled APK (re/apk/src).
4. Encodings marked "?" above.

## Tools
- `tools/scan.py [-v]` – BLE scan
- `tools/gatt_dump.py` – GATT dump
- `tools/probe.py [secs] [--rcsp-info] [--nus HEX..]` – listen / send probes
- `tools/ohw.py` – **main client** (info, battery, firmware, mac, read KEY…, settime, notify, call, steps, hr, spo2, sleep, live-hr, guarded raw send)
- `tools/face.py build BG.png OUT.bin [--color 0-6] [--preview P.png]` / `render FACE.bin DIR` – face builder + decoder
- `tools/devinfo.py` – decode the device-info push
- `tools/remote.py [--log-only]` – watch → Mac remote (actions in `tools/remote_actions.json`)
- `tools/read_settings.sh` – one-session sweep of settings keys (`KEYS="0208 0260"` to pick)
- `tools/pklg_att.py file.pklg` – decode ATT writes/notifies from a PacketLogger capture

Note: BLE scripts must run from the Claude app's Terminal panel (or Terminal.app) — macOS kills
the bare Python process for lacking a Bluetooth usage description. The iPhone's Bluetooth must be
off (or CO FIT disconnected) for the Mac to reach the watch over BLE.

## Hidden features probe (2026-11-05, tools/probe_keys.py → research/captures/probe_all.txt)
READ of all 318 BleKeys (destructive ones skipped: OTA, XMODEM, SHUTDOWN, FACTORY_TEST, passwords, address/name writes).
The watch acks *every* key (empty reply), so only keys returning data prove support.

Returned data: TIME_ZONE, USER_PROFILE, SEDENTARINESS, NO_DISTURB_RANGE, GESTURE_WAKE, NOTIFICATION_REMINDER,
ANTI_LOST, HR_MONITORING (`ff 0000 173b 1e` = on, 00:00–23:59, every 30 min), UI/LANGUAGE_PACK_VERSION,
DRINK_WATER, BLOOD_OXYGEN_SET, WASH_SET, CALORIES_GOAL (kcal×1000), DISTANCE_GOAL (m), SLEEP_GOAL (min, BE16),
DEVICE_INFO, STANDBY_SET, DEVICE_LANGUAGES (15), SOS_SET, WEAR_WAY, BATTERY_USAGE, LOG (0x050b: firmware
log, NUL-separated text lines), CLASSIC_BLUETOOTH_STATE.

Write-tested (tools/lab_test.py; list keys = DELETE 0xff then CREATE items with host-assigned ids 0…n):
| Feature | Key | Item | Result |
|---|---|---|---|
| Alarm | 0x0210 | 28 B: id, en<<7\|repeat(Mon=1…Sun=64), yy-2000,mo,d,h,mi, tag[21] | ✅ stored, listed, rang |
| World clock | 0x0407 | 68 B: local<<7\|id, UTC offset in 15-min units (int8), 00 00, city[62], 00 00 | ✅ shown on watch |
| Stock | 0x0408 | 84 B: id, colour, dp nibbles(chg,price), dp(pct), code[62], 00 00, f32 LE price/chg/pct/cap | ✅ shown on watch |
| Schedule | 0x0403 | 40 B + text | ❌ not stored on this firmware |
| Reminder settings | 0x0209/0221/0226 | en<<7\|days, sh,sm,eh,em, interval | ✅ write + read-back |

## Developer-level findings (2026-11-05)
- **Rename** BT_NAME 0x0242 UPDATE `[len][name≤29][pad to 29][00]` (31 B): ✅ watch drops the link, re-advertises
  with the new name within ~20 s; restoring "OHW-11" works the same way.
- **Factory test** 0x0609 UPDATE: `80` enter → 89 B support report (keys 4, mic/speaker/bio yes, SD/compass/Tuya no,
  name, firmware flag, fw 0.0.3, UI 0.0.1, battery, G-sensor, flash OK, RSSI, hardware IDs, voltage in 0.1 mV);
  `04` → `04 07 xLE yLE zLE` accelerometer (1024 = 1 g), pollable ~6 Hz; `07` motor buzz (felt on the wrist); `83` exit. ✅ all verified.
- GSENSOR_OUTPUT 0x02FA streaming: acked but **no data** on this firmware.
- Device-info flags (decoded with CO FIT's field order): CustomLogo 0 (no boot logo), WorldClock 1, Stock 1,
  ChangeClassicBluetoothState 1, TemperatureUnitSet 1, DateFormatSet 1, BatteryUsage 1, SOSSet2 1, Weather2 1.
- DEVICE_LANGUAGES 0x024F: `[current][4 B][count][codes…]` → 15 languages: en zh tr ru es it pt fr th zh-Hant vi ar fa ms mn.
- Notification with app id `com.whatsapp` shows on the watch (icon lab, 2026-11-05) ✅

## Round 3 (2026-11-05)
- **Host-driven workouts** ✅: APP_SPORT_STATE 0x0604 UPDATE `[mode][state]` (modes 8 indoor, 9 outdoor, 10 cycling,
  13 climbing; states 1 start, 2 resume, 3 pause, 4 end) opens the watch's sport screen; APP_SPORT_DATA 0x0223 UPDATE
  (32 B LE: steps i32, distance m i32, calories i32, duration s i16, spm i16, altitude i16, air pressure i16, pace s/km i32,
  speed f32, mode u8, 3 pad) updates it each second (confirmed on the wrist). The watch pushes REAL_TIME_HEART_RATE 0x0224
  `[time BE32][bpm]…` during the session (bpm is byte 4, not the last byte).
- **ACTIVITY 0x0502 record**: byte 4 = mode(5 bits)|state(3 bits); steps are **24-bit** (bytes 5–7). Reading 32 bits
  gave 67 108 864 steps once a workout record existed.
- BATTERY_USAGE 0x0277 (LE): total, screen-on, talk, speaker, sport, vibrator, idle seconds (i32 each), then three
  voltage records `[yy mm dd hh mi ss][mV×10 u16]` = last boot, last shutdown, latest.
- USER_PROFILE 0x0206: `[unit][gender 1=male][age][height f32 LE][weight f32 LE]` (watch keeps the 11-byte form).
- SOS_SET 0x024E: `[enabled][len][phone…]` padded to 20 B.
- BLOOD_OXYGEN 0x0509 / PRESSURE(stress) 0x050D / BLOOD_PRESSURE 0x0504: 6-B records `[time BE32][value][value2]`;
  WORKOUT2 0x050E: 128-B records (start, end, duration, …, steps, distance, calories, avg/max/min bpm). Empty until worn.

## AI voice & games (2026-11-05)
- CO FIT voice: watch → RECORD_PACKET 0x024B `[time 6][len LE16][status][mode][lang][toLang][ear][aiMode][Opus 16 kHz]`,
  phone → AUDIO_TEXT 0x0410 `[category 0 in/1 out/2 emotion][status][mode][emotion][BleTime 6][utf8 ≤ limit]`.
  Modes: 0 normal, 1 AI watch face, 2 translation, 6 identify, 7 real-time conversation, 10 continuous dialogue.
- On this OHW-11 the AI app shows "no phone" and sends **nothing** over BLE while used; device flags Voice=0,
  AITranslation=0, AICoach=0. It most likely needs a phone's classic-Bluetooth (HFP) link — a Mac can't act as one.
- GAME_CONTROL 0x0612 (`[state][x][y][z]`, states 0 start…5 open G-sensor, 6 close): acked, no stream;
  GameControls=0. The watch's games are local-only; no traffic while playing.
- AUDIO_TEXT 0x0410 push test (input, output normal/going/end, emotion) with the AI app open: all acked, **nothing shown** — the AI app ignores BLE text on this firmware.
- **Correction:** the AI app works when the watch is connected to the Mac as a classic-Bluetooth audio device
  (HFP + A2DP + AVRCP). Tapping it sends the hands-free "voice recognition" request and **macOS opens Siri**, using the
  watch's microphone (macOS default input, 1 ch 16 kHz) and speaker. No BLE traffic at all during the session.
- OHW Studio Assistant: watch mic via HFP → AVAudioEngine (input device pinned to OHW-11) → SFSpeechRecognizer → local commands / Claude → AVSpeechSynthesizer on the watch speaker + notification on the watch screen. Verified by voice on 2026-11-05.

## NFC (2026-11-05)
- CO FIT has **no BLE protocol for NFC**: its only NFC code is a guide screen (`GuideNfcActivity`, `NFCGuideItem`) shown
  when the cloud device config sets `supportNFC`. The guide text: "The watch has a built-in NFC chip and can be used after
  entering the device [menu]. The specific operations are as follows:" followed by pictures. No `BleKey` mentions NFC,
  cards, doors or access; the watch handles NFC entirely on-device (card simulation / tap), with nothing for an app to send.

## Contacts (2026-11-05, research only)
- CO FIT `ContactListActivity.syncContact`: records of 40 B (name UTF-8 ≤ 24 B, phone ≤ 16 B, zero-padded), sent with
  `sendStream(CONTACT 0x0704, bytes)` — same stream framing as WATCH_FACE 0x0701. Empty list → CONTACT DELETE.
- This watch: SupportContactSort 0 → original (V1) format; SupportContactSize 0 → **max 20 contacts**. A sync replaces the list.
- CONTACT READ returned 0 bytes (either no contacts stored or READ unsupported). Upload not yet tested.

### Contacts upload — verified (2026-11-05)
- CONTACT 0x0704 UPDATE via sendStream `[0][total BE32][offset BE32][records]`, 40 B per contact (name UTF-8 24 B + phone 16 B, zero-padded). Up to 20.
- Sent too soon after the handshake the watch answers `14 …` (status 1, error 4 = busy); after ~2–4 s it answers `00 <total> <done>` and the contacts appear in the watch's Contacts app.
- CONTACT DELETE (flag 0x30) clears the list (ack `00`). CONTACT READ returns nothing on this firmware, so the app keeps its own copy of what it sent.

## Deep sweep (2026-11-05)

### JieLi RCSP channel — OPENED
- Auth = Bluetooth E1 (SAFER+) from `libjl_auth.so`, fixed key `06775f87918dd423005df1d8cf0c142b`, address `112233332211`
  (tools/jl_auth.py, Swift port in JieLiChip.swift — outputs match). Raw on AE01/AE02:
  app `00+rand16` → dev `01+E1` → app `02 'pass'` → dev `00+rand16` → app `01+E1` → dev `02 'pass'`.
- Frames `FE DC BA [0x80 cmd|0x40 reply][op][len BE16][sn+params] EF`; replies `[status][sn][data]`.
- TARGET_INFO (op 3, mask ffffffff): protocol 2.0, SDK type 9, chip fw 0.0.0.3, bootloader 1.8.3.4, single-backup OTA
  needing a loader, VID 0x05D6 UID 2 PID 0x0081, MTU 272/540, dual-mode, low-power limit 30 %.
- SYS_INFO fn 0xff (public attrs incl. EQ block) and fn 2 (RTC): chip clock **2020-05-15 19:55:40** (never synced,
  separate from the SMA time) and 10 built-in alarm tones ("提示音0"…9).
- Status 2 (unsupported): FEATURE_MAP 2, EXTERNAL_FLASH_MSG 214, EXTERNAL_FLASH_IO 26 (read), DEVICE_CONFIG 217,
  READ_ERROR_MSG 41, CONNECTED_PHONE 49. FILE_BROWSE 12 → ok but empty (device sends STOP 13). No flash dump possible.

### Full SMA key sweep (tools/sweep_keys.py → research/captures/sweep_02.txt, sweep_rest.txt)
- READ of every key in groups 02–06 and 08: the watch acks every key, data only from known BleKeys — no undocumented keys.
  Group 02: 46 data keys; 03: IDENTITY; 04: MUSIC_CONTROL, WEATHER x4; 05: ACTIVITY, HEART_RATE, LOG; 06: CLASSIC_BT_STATE.
- Keys with data that the device-info flags don't advertise: GIRL_CARE 021A, GIRL_CARE_MONTHLY 026C, TEMPERATURE_DETECTING 021B,
  TEMPERATURE_UNIT 021D, EARPHONE_CALL 0263, RAW_SLEEP 02FE, SLEEP_QUALITY 0219.

### Hidden features tested
- **Cycle tracking (GIRL_CARE 0x021A) ✅ hidden but working**: 10 B `[reminder<<7|enabled][hh][mm][period-adv][ovul-adv][yy][mo][dd][len][cycle]`.
  Enabling adds a cycle screen on the watch and its reminder fired at the set time. Original value `00140001031a071a051c` (off).
- REALTIME_MEASUREMENT 0x0236 (`0x40|bit` start, `0x80|bit` stop): acked, watch does nothing, no pushes.

### Firmware
- Vendor endpoint `https://api.iot-solution.net/kotlinweb/ble_firmware_version/latest` (bleName OHW-11, flag WATCH11_HWZFB_OHW,
  version 0): "There is no upgrade firmware package". No firmware image available → the watch's own menu/app list
  can't be extracted; Bluetooth gives no menu listing either.
