"""Try hidden features: python hidden_test.py measure hr|spo2|bp|stress  |  girlcare on|restore"""
import asyncio, sys, os, time
from datetime import datetime, timedelta
sys.path.insert(0, os.path.dirname(__file__))
import ohw
BITS = {"hr": 1, "spo2": 2, "bp": 4, "stress": 8, "temp": 16, "hrv": 32}
async def listen(w, secs):
    t0 = time.monotonic()
    while time.monotonic() - t0 < secs:
        try: k, fl, d = await asyncio.wait_for(w.q.get(), 0.5)
        except asyncio.TimeoutError: continue
        print(f"  {time.monotonic()-t0:5.1f}s {k:04x} fl={fl:02x} {d.hex()}")
async def main():
    mode, arg = sys.argv[1], sys.argv[2]
    async with ohw.Watch(verbose=False) as w:
        await w.handshake(wait_info=True); await asyncio.sleep(2)
        while not w.q.empty(): w.q.get_nowait()
        if mode == "measure":
            b = BITS[arg]
            print(f"start {arg} measurement"); await w.send(0x0236, 0x00, bytes([0x40 | b]))
            await listen(w, 45)
            print("stop"); await w.send(0x0236, 0x00, bytes([0x80 | b])); await listen(w, 3)
        elif mode == "girlcare":
            if arg == "on":
                t = datetime.now() + timedelta(minutes=1)
                last = datetime.now() - timedelta(days=26)   # period due in ~2 days
                d = bytes([0x81, t.hour, t.minute, 2, 3, last.year - 2000, last.month, last.day, 5, 28])
            else:
                d = bytes.fromhex("00140001031a071a051c")
            await w.send(0x021a, 0x00, d); await listen(w, 2)
            await w.send(0x021a, 0x10); await listen(w, 2)
            if arg == "on": print("enabled; reminder set for", (datetime.now() + timedelta(minutes=1)).strftime("%H:%M")); await listen(w, 90)
asyncio.run(main())
