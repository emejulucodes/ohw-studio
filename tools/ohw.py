#!/usr/bin/env python3
"""OHW-11 control client for the SMA "AB" protocol over Nordic UART (bleak / macOS).

Frame:   AB | flags | len(BE16) | crc16-ARC(BE16) | payload
payload: [BleKey BE16][BleKeyFlag][data]
Protocol reference: reference/sma-protocol (bdrtr/dsmart-r18-sma-protocol), verified there on a JieLi watch.

Run from the Claude Terminal panel or Terminal.app (needs macOS Bluetooth permission),
with the iPhone's Bluetooth off so the watch is free.

usage:
  ohw.py info                      handshake + device-info push
  ohw.py battery | firmware | mac
  ohw.py read KEY                  raw READ of a BleKey (hex, e.g. 0x0208)
  ohw.py settime                   set watch clock to this Mac's local time
  ohw.py notify TITLE BODY         push an app notification
  ohw.py call NAME [NUMBER]        incoming-call screen (vibrates)
  ohw.py steps | hr | spo2 | sleep health history
  ohw.py live-hr                   real-time heart rate (wear the watch)
  ohw.py send KEY FLAG [HEXDATA]   raw frame (guarded: dangerous keys blocked)
  ohw.py face FACE.bin             upload a watch face built with tools/face.py
"""
import asyncio, struct, sys, time
from datetime import datetime, timedelta
from bleak import BleakScanner, BleakClient

NAME = "OHW-11"
RX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"   # write
TX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"   # notify

UPDATE, READ, READ_CONT, CREATE, DELETE, RESET = 0x00, 0x10, 0x11, 0x20, 0x30, 0x40
K = dict(TIME=0x0201, POWER=0x0203, FIRMWARE=0x0204, BLE_ADDRESS=0x0205, IDENTITY=0x0301,
         NOTIFICATION=0x0401, ACTIVITY=0x0502, HEART_RATE=0x0503, SLEEP=0x0505,
         BLOOD_OXYGEN=0x0509, REAL_TIME_HR=0x0224)
# keys that could brick / wipe / shut down / change identity: refuse in raw `send`
DANGEROUS = {0x0101, 0x0102, 0x0222, 0x0235, 0x024c, 0x0609, 0x0242} | set(range(0x0701, 0x0721))
EPOCH = datetime(2000, 1, 1)
import os
REPLY_MODE = os.environ.get("OHW_REPLY", "empty")   # how to answer watch-initiated commands: empty|status|none


def crc16_arc(data: bytes) -> int:
    crc = 0
    for b in data:
        crc ^= b
        for _ in range(8):
            crc = (crc >> 1) ^ 0xA001 if crc & 1 else crc >> 1
    return crc


def frame(key: int, flag: int, data: bytes = b"") -> bytes:
    p = struct.pack(">HB", key, flag) + data
    return struct.pack(">BBHH", 0xAB, 0x01, len(p), crc16_arc(p)) + p


class Watch:
    def __init__(self, verbose=True):
        self.buf = bytearray(); self.q = asyncio.Queue(); self.v = verbose
        self.on_command = None          # callback(key, flag, data) for watch-initiated commands
        self.disconnected = asyncio.Event()

    def _on(self, _, d: bytearray):
        self.buf += d
        while True:
            i = self.buf.find(b"\xab")
            if i < 0 or len(self.buf) < i + 6:
                if i > 0: del self.buf[:i]
                return
            n = struct.unpack_from(">H", self.buf, i + 2)[0]
            if len(self.buf) < i + 6 + n: return
            hflags = self.buf[i + 1]
            crc = struct.unpack_from(">H", self.buf, i + 4)[0]
            p = bytes(self.buf[i + 6:i + 6 + n]); del self.buf[:i + 6 + n]
            if n >= 3:
                key, flag = struct.unpack_from(">HB", p)
                if self.v:
                    ok = "ok" if crc16_arc(p) == crc else "BADCRC"
                    print(f"  <- [hdr 0x{hflags:02x}] key=0x{key:04x} flag=0x{flag:02x} {ok} ({n-3}B) {p[3:].hex()}")
                self.q.put_nowait((key, flag, p[3:]))
                if hflags == 0x01 and REPLY_MODE != "none":
                    # the watch sent us a *command*; answer it like the watch answers ours.
                    # CAMERA (0x0601): the app echoes the state byte back (BaseBleConnector.handleData).
                    extra = b"\x00" if REPLY_MODE == "status" else b""
                    if key == 0x0601 and len(p) > 3: extra = p[3:4]
                    rp = struct.pack(">HB", key, flag) + extra
                    rf = struct.pack(">BBHH", 0xAB, 0x11, len(rp), crc16_arc(rp)) + rp
                    if self.v: print(f"  -> reply {rf.hex()}")
                    asyncio.get_event_loop().create_task(self.c.write_gatt_char(RX, rf, response=False))
                    if self.on_command:
                        self.on_command(key, flag, p[3:])
            elif self.v:
                print(f"  <- [hdr 0x{hflags:02x}] short frame ({n}B) {p.hex()}")

    async def __aenter__(self):
        dev = None
        for _ in range(6):   # watch needs a few seconds to re-advertise after a disconnect
            dev = await BleakScanner.find_device_by_name(NAME, timeout=10)
            if dev: break
        if not dev:
            sys.exit("watch not found - is iPhone Bluetooth off and the watch nearby?")
        self.c = BleakClient(dev, timeout=15, disconnected_callback=lambda _: self.disconnected.set())
        await asyncio.wait_for(self.c.connect(), 20)
        await self.c.start_notify(TX, self._on)
        return self

    async def __aexit__(self, *a):
        try: await self.c.disconnect()
        except Exception: pass

    async def send(self, key, flag, data=b""):
        f = frame(key, flag, data)
        if self.v: print(f"  -> key=0x{key:04x} flag=0x{flag:02x} {f.hex()}")
        mtu = max(20, self.c.mtu_size - 3)
        for i in range(0, len(f), mtu):
            await self.c.write_gatt_char(RX, f[i:i + mtu], response=False)

    async def wait(self, key, timeout=4.0):
        end = time.monotonic() + timeout
        while (left := end - time.monotonic()) > 0:
            try: k, fl, d = await asyncio.wait_for(self.q.get(), left)
            except asyncio.TimeoutError: break
            if k == key: return d
        return None

    async def collect(self, key, timeout=6.0, idle=1.5):
        """Gather all frames for key until `idle` s of silence."""
        out, end = b"", time.monotonic() + timeout
        while time.monotonic() < end:
            try: k, fl, d = await asyncio.wait_for(self.q.get(), idle)
            except asyncio.TimeoutError:
                if out: break
                continue
            if k == key: out += d
        return out

    async def handshake(self, wait_info=False):
        await self.send(K["IDENTITY"], CREATE, bytes.fromhex("284667c2"))
        ack = await self.wait(K["IDENTITY"], 3)
        info = await self.wait(K["IDENTITY"], 9) if wait_info else None
        return ack, info


def fixstr(s: str, n: int) -> bytes:
    b = s.encode()[: n - 1]
    return b + b"\0" * (n - len(b))


def now_bytes():
    t = datetime.now()
    return bytes([t.year - 2000, t.month, t.day, t.hour, t.minute, t.second])


def ts(sec): return (EPOCH + timedelta(seconds=sec)).strftime("%Y-%m-%d %H:%M")


async def main(argv):
    if not argv: print(__doc__); return
    cmd, args = argv[0], argv[1:]
    async with Watch() as w:
        ack, info = await w.handshake(wait_info=(cmd in ("info", "face")))
        print("handshake:", "OK" if ack == b"\x00" else f"unexpected {ack!r}")
        if cmd == "info":
            if info:
                txt = " | ".join(s.decode(errors="replace") for s in info.split(b"\0") if len(s) > 1 and all(32 <= c < 127 for c in s))
                print("device info strings:", txt)
            return
        if cmd in ("battery", "firmware", "mac"):
            key = {"battery": "POWER", "firmware": "FIRMWARE", "mac": "BLE_ADDRESS"}[cmd]
            await w.send(K[key], READ); d = await w.wait(K[key])
            if d is None: print("no response"); return
            if cmd == "battery": print(f"battery: {d[0]}%")
            elif cmd == "firmware": print("firmware:", ".".join(map(str, d[:3])))
            else: print("mac:", ":".join(f"{b:02X}" for b in reversed(d[:6])))  # little-endian
        elif cmd == "read":
            for a in args:   # several small reads share one connection
                key = int(a, 16); await w.send(key, READ)
                d = await w.wait(key, 2.5)
                print(f"0x{key:04x} -> {d.hex() if d is not None else 'no response'}", flush=True)
        elif cmd == "settime":
            await w.send(K["TIME"], UPDATE, now_bytes()); print("reply:", await w.wait(K["TIME"]))
        elif cmd in ("notify", "call"):
            cat = 127 if cmd == "notify" else 1
            title = args[0] if args else "Hello"
            body = " ".join(args[1:]) if len(args) > 1 else ("from my Mac" if cat == 127 else "")
            pkg = "com.apple.MobileSMS" if cat == 127 else "com.apple.mobilephone"
            data = bytes([cat]) + now_bytes() + fixstr(pkg, 32) + fixstr(title, 32) + body.encode()[:250]
            await w.send(K["NOTIFICATION"], UPDATE, data); print("reply:", await w.wait(K["NOTIFICATION"]))
        elif cmd == "steps":
            await w.send(K["ACTIVITY"], READ); d = await w.collect(K["ACTIVITY"], 10)
            for i in range(0, len(d) - 15, 16):
                t, s, cal, dist = struct.unpack_from(">IIII", d, i)
                print(f"{ts(t)}  steps={s}  kcal={cal/1e4:.1f}  dist={dist/1e4:.0f}m")
            if not d: print("no records")
        elif cmd in ("hr", "spo2"):
            key = K["HEART_RATE"] if cmd == "hr" else K["BLOOD_OXYGEN"]
            await w.send(key, READ); d = await w.collect(key, 10)
            for i in range(0, len(d) - 5, 6):
                t, v = struct.unpack_from(">IB", d, i); print(f"{ts(t)}  {v}")
            if not d: print("no records")
        elif cmd == "sleep":
            await w.send(K["SLEEP"], READ); d = await w.collect(K["SLEEP"], 10)
            modes = {1: "deep", 2: "light", 3: "awake", 9: "REM", 17: "start", 34: "end"}
            for i in range(0, len(d) - 6, 7):
                t, m = struct.unpack_from(">IB", d, i); print(f"{ts(t)}  {modes.get(m, m)}")
            if not d: print("no records")
        elif cmd == "live-hr":
            await w.send(K["REAL_TIME_HR"], UPDATE, b"\x01")
            end = time.monotonic() + 20
            while time.monotonic() < end:
                d = await w.wait(K["REAL_TIME_HR"], end - time.monotonic())
                if d: print("HR:", d[-1])
            await w.send(K["REAL_TIME_HR"], UPDATE, b"\x00")
        elif cmd == "face":
            # BleConnector.sendStream(WATCH_FACE, bytes, position 0): packets are
            # [type u8][total BE32][offset BE32][<= IO buffer bytes]; the watch answers each with
            # BleStreamProgress [status:4|error:4][total BE32][completed BE32] and we continue
            # from `completed` until completed == total (status != 0 aborts).
            blob = open(args[0], "rb").read()
            chunk, slot, key = 1018, 0, 0x0701       # mIOBufferSize from the device info
            w.v = False
            print("device info push:", "received+answered" if info else "not seen")
            await asyncio.sleep(3)                   # let the watch finish its post-connect work
            while not w.q.empty(): w.q.get_nowait()
            off, t0, busy = 0, time.monotonic(), 0
            print(f"uploading {len(blob)} bytes in {(len(blob) + chunk - 1)//chunk} packets")
            while True:
                part = blob[off:off + chunk]
                await w.send(key, UPDATE, struct.pack(">BII", slot, len(blob), off) + part)
                d = await w.wait(key, 10)
                if d is None or len(d) < 9:
                    print(f"\nno/short progress reply at offset {off}: {d!r}"); return
                status, err = d[0] >> 4, d[0] & 0xF
                total, done = struct.unpack_from(">II", d, 1)
                print(f"\r  {done}/{total} bytes ({100*done//max(total,1)}%) status={status} err={err}", end="", flush=True)
                if status != 0 and err == 4 and busy < 5:   # "device busy, sync later"
                    busy += 1; print(f"\n  watch busy (raw {d.hex()}), retry {busy}/5 in 3 s")
                    await asyncio.sleep(3); off = 0; continue
                if status != 0:
                    print(f"\nwatch rejected the face: status={status} error={err} raw={d.hex()}"); return
                if done >= total:
                    print(f"\ndone in {time.monotonic()-t0:.1f}s"); return
                off = done                           # next packet starts where the watch says
        elif cmd == "send":
            key, flag = int(args[0], 16), int(args[1], 16)
            if key in DANGEROUS or flag in (DELETE, RESET):
                sys.exit(f"refusing 0x{key:04x}/0x{flag:02x}: could wipe/brick/shut down the watch")
            await w.send(key, flag, bytes.fromhex(args[2]) if len(args) > 2 else b"")
            d = await w.collect(key, 5); print("reply:", d.hex() if d else None)
        else:
            print(__doc__)


if __name__ == "__main__":
    try:
        asyncio.run(asyncio.wait_for(main(sys.argv[1:]), 900))
    except asyncio.TimeoutError:
        sys.exit("timed out (watch busy or out of range)")
