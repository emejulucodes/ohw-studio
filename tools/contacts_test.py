"""Upload test contacts via CONTACT 0x0704 stream (40-byte records: name 24 B, phone 16 B), then read back."""
import asyncio, sys, os, struct
sys.path.insert(0, os.path.dirname(__file__))
import ohw
def rec(name, phone):
    return name.encode()[:24].ljust(24, b"\0") + phone.encode()[:16].ljust(16, b"\0")
async def main():
    blob = rec("OHW Test", "12345") + rec("Studio Two", "+2348000000000")
    async with ohw.Watch(verbose=True) as w:
        await w.handshake(wait_info=True); await asyncio.sleep(1.5)
        while not w.q.empty(): w.q.get_nowait()
        data = bytes([0]) + struct.pack(">II", len(blob), 0) + blob
        await asyncio.sleep(4)
        for attempt in range(4):
            await w.send(0x0704, 0x00, data)
            r = await w.wait(0x0704, 8)
            print("attempt", attempt, "reply:", r.hex() if r else None)
            if r and r[0] >> 4 == 0: break
            await asyncio.sleep(4)
        await asyncio.sleep(2)
        while not w.q.empty(): w.q.get_nowait()
        await w.send(0x0704, 0x10)
        d = await w.collect(0x0704, 6, 1.5)
        print("read back bytes:", len(d), d[:80].hex())
asyncio.run(main())
