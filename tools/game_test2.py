"""GAME_CONTROL: START(0) then OPEN_GSENSOR(5); listen; then END(4)/CLOSE(6)."""
import asyncio, sys, os, time, struct
sys.path.insert(0, os.path.dirname(__file__))
import ohw
async def main():
    async with ohw.Watch(verbose=False) as w:
        await w.handshake(wait_info=True); await asyncio.sleep(1)
        while not w.q.empty(): w.q.get_nowait()
        for st in (0, 5):
            await w.send(0x0612, 0x00, bytes([st, 0, 0, 0, 0, 0, 0, 0])); await asyncio.sleep(0.3)
        t0 = time.monotonic(); n = 0
        while time.monotonic() - t0 < 10:
            try: k, fl, d = await asyncio.wait_for(w.q.get(), 0.5)
            except asyncio.TimeoutError: continue
            n += 1
            if n <= 10 or n % 20 == 0:
                print(f"{time.monotonic()-t0:5.2f}s {k:04x} fl={fl:02x} {len(d)}B {d[:24].hex()}")
        for st in (6, 4):
            await w.send(0x0612, 0x00, bytes([st, 0, 0, 0, 0, 0, 0, 0])); await asyncio.sleep(0.3)
        print("frames", n)
asyncio.run(main())
