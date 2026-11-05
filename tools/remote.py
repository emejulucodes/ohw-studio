#!/usr/bin/env python3
"""Use the OHW-11 as a remote for this Mac.

Stays connected to the watch, logs every command the watch sends (hdr 0x01 frames) and runs the
shell command mapped to it in tools/remote_actions.json. Reconnects automatically.

Decoded from CO FIT (com.szabh.smable3):
  MUSIC_CONTROL 0x0402 : data[0] = 0 play, 1 pause, 2 toggle, 3 next, 4 prev, 5 vol+, 6 vol-
  CAMERA        0x0601 : data[0] = 0 exit, 1 enter, 2 capture, 3 exchange  (reply echoes the byte)
  FIND_PHONE    0x0213 : data[0] = 1 start / 0 stop

usage: remote.py [--config FILE] [--log-only]
Run from the Terminal panel (Bluetooth permission) with iPhone Bluetooth off.
"""
import argparse, asyncio, json, os, subprocess, sys, time
sys.path.insert(0, os.path.dirname(__file__))
import ohw

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
MUSIC = {0: "play", 1: "pause", 2: "toggle", 3: "next", 4: "prev", 5: "volume_up", 6: "volume_down"}
CAMERA = {0: "exit", 1: "enter", 2: "capture", 3: "exchange"}
KEYNAMES = {k: n for n, k in vars(ohw).get("K", {}).items()}


def event_name(key, flag, data):
    b = data[0] if data else None
    if key == 0x0402: return "music." + MUSIC.get(b, f"cmd{b}")
    if key == 0x0601: return "camera." + CAMERA.get(b, f"state{b}")
    if key == 0x0213: return "find_phone." + ("start" if b else "stop")
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--config", default=os.path.join(HERE, "remote_actions.json"))
    ap.add_argument("--log-only", action="store_true", help="only print events, run nothing")
    a = ap.parse_args()

    def run(ev):
        try: cfg = json.load(open(a.config))            # re-read so edits apply live
        except Exception as e: print("  config error:", e); return
        cmd = cfg.get(ev, cfg.get("unknown", ""))
        if a.log_only or not cmd: return
        print(f"  -> {cmd}")
        subprocess.Popen(cmd, shell=True, cwd=ROOT)

    last = {}
    def on_command(key, flag, data):
        if key == 0x0301: return                         # device-info push after handshake
        ev = event_name(key, flag, data)
        ts = time.strftime("%H:%M:%S")
        print(f"[{ts}] watch -> key=0x{key:04x} flag=0x{flag:02x} data={data.hex()}  {ev or '(unmapped)'}", flush=True)
        if ev:
            now = time.monotonic()
            if now - last.get(ev, 0) < 0.4: return        # debounce duplicate sends
            last[ev] = now; run(ev)
            if ev.startswith("music."):       # update the watch soon after the player reacts
                r = ev_holder.get("refresh")
                if r: asyncio.get_event_loop().call_later(0.7, r.set)
        else:
            run("unknown")

    ev_holder = {}

    async def now_playing_loop(w):
        """Mirror Spotify/Music now-playing onto the watch music screen.
        MUSIC_CONTROL UPDATE [entity][attr][utf8]; watch subscribes to PLAYER playback-info(1) +
        volume(2) and TRACK title(2). Playback info = "state,rate,elapsed" (state 0 paused, 1 playing)."""
        last = {}
        refresh = ev_holder["refresh"] = asyncio.Event()
        script = os.path.join(HERE, "nowplaying.applescript")
        while not w.disconnected.is_set():
            try:
                p = await asyncio.create_subprocess_exec("osascript", script, stdout=asyncio.subprocess.PIPE,
                                                         stderr=asyncio.subprocess.DEVNULL)
                out = (await asyncio.wait_for(p.communicate(), 8))[0].decode().strip()
            except Exception:
                out = ""
            if out:
                _, st, title, artist, pos, vol = (out.split("|") + [""] * 6)[:6]
                playing = st == "playing"
                shown = f"{title} - {artist}" if artist else title
                items = {
                    (2, 2): shown[:60] or " ",
                    (0, 1): f"{1 if playing else 0},{1.0 if playing else 0.0:.1f},{pos or 0}",
                    (0, 2): f"{(int(vol or 0)) / 100:.2f}",
                }
                for (ent, attr), val in items.items():
                    # resend title/state when they change; position-only changes don't spam the link
                    k = (ent, attr)
                    cmp = val.rsplit(",", 1)[0] if k == (0, 1) else val
                    if last.get(k) != cmp:
                        last[k] = cmp
                        await w.send(0x0402, ohw.UPDATE, bytes([ent, attr]) + val.encode())
                        if k == (2, 2): print(f"  now playing -> watch: {val}", flush=True)
            refresh.clear()
            try: await asyncio.wait_for(refresh.wait(), 2.0)
            except asyncio.TimeoutError: pass

    async def session():
        async with ohw.Watch(verbose=False) as w:
            w.on_command = on_command
            ack, info = await w.handshake(wait_info=True)
            state = "handshake ok" if ack == bytes([0]) else "handshake ?"
            print(f"connected ({state}) - press buttons on the watch; Ctrl-C to quit", flush=True)
            np = asyncio.create_task(now_playing_loop(w))
            await w.disconnected.wait()
            np.cancel()
            print("watch disconnected", flush=True)

    async def loop():
        while True:
            try: await session()
            except SystemExit as e: print(e)
            except Exception as e: print("session error:", e)
            print("reconnecting in 5 s ..."); await asyncio.sleep(5)

    try: asyncio.run(loop())
    except KeyboardInterrupt: print("\nbye")


if __name__ == "__main__":
    main()
