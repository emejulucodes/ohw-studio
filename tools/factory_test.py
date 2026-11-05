"""Enter factory test mode, request the G-sensor test, listen, then always exit (0x83)."""
import asyncio, sys, os, time
sys.path.insert(0, os.path.dirname(__file__))
import ohw

async def listen(w, secs, label):
    t0 = time.monotonic()
    while time.monotonic() - t0 < secs:
        try: k, fl, d = await asyncio.wait_for(w.q.get(), 0.5)
        except asyncio.TimeoutError: continue
        print(f"  [{label}] key=0x{k:04x} flag={fl:02x} {len(d)}B {d[:48].hex()}")

async def main():
    async with ohw.Watch(verbose=False) as w:
        await w.handshake(wait_info=True)
        await asyncio.sleep(1)
        while not w.q.empty(): w.q.get_nowait()
        try:
            await w.send(0x0609, 0x00, b"\x80"); await listen(w, 3, "enter")
            await w.send(0x0609, 0x00, b"\x04"); await listen(w, 6, "gsensor")
        finally:
            await w.send(0x0609, 0x00, b"\x83"); await listen(w, 2, "exit")
        print("done (sent EXIT)")

asyncio.run(main())
