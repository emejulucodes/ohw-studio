"""Read the watch's contact list (CONTACT 0x0704 READ) without changing anything."""
import asyncio, sys, os
sys.path.insert(0, os.path.dirname(__file__))
import ohw
async def main():
    async with ohw.Watch(verbose=True) as w:
        await w.handshake(wait_info=True); await asyncio.sleep(1)
        while not w.q.empty(): w.q.get_nowait()
        await w.send(0x0704, 0x10)
        d = await w.collect(0x0704, 6, 1.5)
        print("bytes:", len(d))
        for i in range(0, len(d) - 39, 40):
            name = d[i:i+24].split(b"\0")[0].decode("utf-8", "replace"); phone = d[i+24:i+40].split(b"\0")[0].decode("utf-8", "replace")
            print(f"  {i//40+1:2d}. {name!r} {'*' * max(0, len(phone)-3) + phone[-3:]}")
asyncio.run(main())
