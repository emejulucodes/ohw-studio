"""Start an outdoor run from the host and stream APP_SPORT_DATA (0x0223) like CO FIT's phone-GPS mode."""
import asyncio, sys, os, time, struct
sys.path.insert(0, os.path.dirname(__file__))
import ohw

def sport_data(step, dist_m, kcal, dur_s, spm, pace_s, speed, mode=9):
    return (struct.pack("<iiihhhh", step, dist_m, kcal, dur_s, spm, 0, 0) + struct.pack("<i", pace_s)
            + struct.pack("<f", speed) + bytes([mode]) + b"\0\0\0")

async def main():
    secs = int(sys.argv[1]) if len(sys.argv) > 1 else 30
    async with ohw.Watch(verbose=False) as w:
        await w.handshake(wait_info=True)
        await asyncio.sleep(1)
        await w.send(0x0604, 0x00, bytes([9, 1])); print("start ->", await w.wait(0x0604, 3))
        for t in range(1, secs + 1):
            d = sport_data(step=t * 3, dist_m=t * 3, kcal=t * 200, dur_s=t, spm=170, pace_s=330, speed=10.9)
            await w.send(0x0223, 0x00, d)
            got = []
            end = time.monotonic() + 1
            while time.monotonic() < end:
                try: k, fl, x = await asyncio.wait_for(w.q.get(), end - time.monotonic())
                except asyncio.TimeoutError: break
                got.append(f"{k:04x}:{x.hex()[:40]}")
            if t <= 3 or got[1:]: print(t, got)
        await w.send(0x0604, 0x00, bytes([9, 4])); print("end ->", await w.wait(0x0604, 3))

asyncio.run(main())
