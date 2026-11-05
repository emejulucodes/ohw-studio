"""READ-sweep every key in groups 0x02-0x06 and 0x08-0x0f (skips 0x01 OTA and 0x07 streams) and record
whether the watch acks, returns data, or ignores it.  usage: python sweep_keys.py OUT.txt [groups hex,…]"""
import asyncio, sys, os, time
sys.path.insert(0, os.path.dirname(__file__))
import ohw

async def main():
    out = open(sys.argv[1], "w")
    groups = [int(g, 16) for g in sys.argv[2].split(",")] if len(sys.argv) > 2 else [2, 3, 4, 5, 6, 8, 9, 10, 11, 12, 13, 14, 15]
    async with ohw.Watch(verbose=False) as w:
        await w.handshake(wait_info=True); await asyncio.sleep(2)
        while not w.q.empty(): w.q.get_nowait()
        stats = {}
        for g in groups:
            for lo in range(256):
                k = (g << 8) | lo
                if k in (0x0222, 0x0609, 0x0235, 0x024c, 0x0242, 0x0101, 0x0102): continue
                await w.send(k, 0x10)
                got, t0 = [], time.monotonic()
                while time.monotonic() - t0 < 0.35:
                    try: kk, fl, d = await asyncio.wait_for(w.q.get(), 0.35)
                    except asyncio.TimeoutError: break
                    got.append((kk, fl, d))
                    if kk == k and fl == 0x10: break
                mine = [d for kk, fl, d in got if kk == k]
                other = [(kk, fl, d) for kk, fl, d in got if kk != k]
                kind = "data" if any(mine) else "ack" if mine else "none"
                stats.setdefault(g, {}).setdefault(kind, 0); stats[g][kind] += 1
                line = f"{k:04x} {kind} " + " | ".join(d.hex() for d in mine if d)[:400]
                if other: line += "  OTHER " + " ".join(f"{a:04x}/{b:02x}:{c[:16].hex()}" for a, b, c in other)
                out.write(line + "\n"); out.flush()
                if kind != "ack" or other: print(line[:200])
                if w.disconnected.is_set(): print("DISCONNECTED at", hex(k)); return
            print(f"group {g:02x}: {stats[g]}")
    out.close()
asyncio.run(main())
