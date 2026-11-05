"""Turn on the hidden accelerometer stream (GSENSOR_OUTPUT 0x02FA) for a few seconds and print what arrives."""
import asyncio, sys, os, struct, time
sys.path.insert(0, os.path.dirname(__file__))
import ohw

async def main():
    secs = float(sys.argv[1]) if len(sys.argv) > 1 else 8
    async with ohw.Watch(verbose=False) as w:
        await w.handshake(wait_info=True)
        await asyncio.sleep(1)
        while not w.q.empty(): w.q.get_nowait()
        await w.send(0x02FA, 0x00, b"\x01")
        t0 = time.monotonic(); n = 0; keys = {}
        while time.monotonic() - t0 < secs:
            try: k, fl, d = await asyncio.wait_for(w.q.get(), 0.5)
            except asyncio.TimeoutError: continue
            keys[k] = keys.get(k, 0) + 1; n += 1
            if n <= 12 or n % 20 == 0:
                s = [struct.unpack_from(">hhh", d, i) for i in range(0, len(d) - 5, 6)][:4]
                print(f"{time.monotonic()-t0:5.2f}s key=0x{k:04x} flag={fl:02x} {len(d)}B first={s}")
        await w.send(0x02FA, 0x00, b"\x00")
        await asyncio.sleep(1)
        print("frames:", n, {f"0x{k:04x}": c for k, c in keys.items()})

asyncio.run(main())
