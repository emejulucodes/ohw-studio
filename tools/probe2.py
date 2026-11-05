"""Second hardware probe: health histories + starting a workout from the host (APP_SPORT_STATE 0x0604)."""
import asyncio, sys, os, time
sys.path.insert(0, os.path.dirname(__file__))
import ohw

async def listen(w, secs):
    t0 = time.monotonic()
    while time.monotonic() - t0 < secs:
        try: k, fl, d = await asyncio.wait_for(w.q.get(), 0.5)
        except asyncio.TimeoutError: continue
        print(f"  {time.monotonic()-t0:5.1f}s key=0x{k:04x} flag={fl:02x} {len(d)}B {d[:64].hex()}")

async def main():
    async with ohw.Watch(verbose=False) as w:
        await w.handshake(wait_info=True)
        await asyncio.sleep(1)
        for k, n in [(0x0504, "BLOOD_PRESSURE"), (0x0509, "BLOOD_OXYGEN"), (0x050d, "PRESSURE"), (0x050e, "WORKOUT2"),
                     (0x0219, "SLEEP_QUALITY"), (0x0503, "HEART_RATE"), (0x0505, "SLEEP")]:
            while not w.q.empty(): w.q.get_nowait()
            await w.send(k, 0x10)
            d = await w.collect(k, 6, 1.2)
            print(f"{n:16s} {len(d)}B {d[:96].hex()}")
        print("\n== start outdoor run from host")
        while not w.q.empty(): w.q.get_nowait()
        await w.send(0x0604, 0x00, bytes([9, 1])); await listen(w, 12)
        print("== end")
        await w.send(0x0604, 0x00, bytes([9, 4])); await listen(w, 4)

asyncio.run(main())
