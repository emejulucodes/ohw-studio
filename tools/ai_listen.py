"""Listen to every BLE frame for N seconds (AI voice app test while classic audio is connected)."""
import asyncio, sys, os, time, struct
sys.path.insert(0, os.path.dirname(__file__))
import ohw
async def main():
    secs = int(sys.argv[1]) if len(sys.argv) > 1 else 60
    async with ohw.Watch(verbose=False) as w:
        await w.handshake(wait_info=True); await asyncio.sleep(1)
        while not w.q.empty(): w.q.get_nowait()
        print(f"LISTENING {secs}s — open the AI app and speak now", flush=True)
        t0 = time.monotonic(); tot = {}
        while time.monotonic() - t0 < secs:
            try: k, fl, d = await asyncio.wait_for(w.q.get(), 0.5)
            except asyncio.TimeoutError: continue
            tot[k] = tot.get(k, 0) + 1
            if tot[k] <= 6 or tot[k] % 20 == 0:
                extra = ""
                if k == 0x024b and len(d) >= 14:
                    extra = f" RECORD len={struct.unpack_from('<H', d, 6)[0]} status={d[8]} mode={d[9]} lang={d[10]} ai={d[13]}"
                print(f"{time.monotonic()-t0:5.1f}s {k:04x} fl={fl:02x} {len(d)}B {d[:32].hex()}{extra}", flush=True)
        print("frames per key:", {f"{k:04x}": v for k, v in tot.items()})
asyncio.run(main())
