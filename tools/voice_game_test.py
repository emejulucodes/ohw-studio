"""Phase A: GAME_CONTROL 0x0612 open-gsensor stream (8 s). Phase B: listen for everything (AI voice / game apps)."""
import asyncio, sys, os, time, struct
sys.path.insert(0, os.path.dirname(__file__))
import ohw

async def main():
    listen_s = int(sys.argv[1]) if len(sys.argv) > 1 else 75
    async with ohw.Watch(verbose=False) as w:
        await w.handshake(wait_info=True)
        await asyncio.sleep(1)
        while not w.q.empty(): w.q.get_nowait()
        print("== A: GAME_CONTROL open gsensor")
        await w.send(0x0612, 0x00, bytes([5, 0, 0, 0, 0, 0, 0, 0]))
        t0 = time.monotonic(); n = 0
        while time.monotonic() - t0 < 8:
            try: k, fl, d = await asyncio.wait_for(w.q.get(), 0.5)
            except asyncio.TimeoutError: continue
            n += 1
            if n <= 8 or n % 25 == 0:
                xyz = struct.unpack_from("<hhh", d, 1) if len(d) >= 7 else None
                print(f"  {time.monotonic()-t0:5.2f}s {k:04x} fl={fl:02x} {len(d)}B {d[:20].hex()} xyz={xyz}")
        await w.send(0x0612, 0x00, bytes([6, 0, 0, 0, 0, 0, 0, 0]))
        await asyncio.sleep(0.5)
        print(f"  frames: {n}")
        print(f"\n== B: listening {listen_s}s — open the AI voice app on the watch and speak, then try the game app")
        t0 = time.monotonic(); sizes = {}; first = {}
        while time.monotonic() - t0 < listen_s:
            try: k, fl, d = await asyncio.wait_for(w.q.get(), 0.5)
            except asyncio.TimeoutError: continue
            sizes[k] = sizes.get(k, 0) + len(d)
            if k not in first or k != 0x024b:
                first.setdefault(k, 0)
                print(f"  {time.monotonic()-t0:5.1f}s {k:04x} fl={fl:02x} {len(d)}B {d[:40].hex()}")
            elif k == 0x024b and len(d) >= 14:
                print(f"  {time.monotonic()-t0:5.1f}s RECORD len={struct.unpack_from('<H', d, 6)[0]} status={d[8]} mode={d[9]} ai={d[13]}")
        print("bytes per key:", {f"{k:04x}": v for k, v in sizes.items()})

asyncio.run(main())
