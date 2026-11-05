"""READ-probe every known BleKey (except destructive ones) and log what the watch answers.
usage: python probe_keys.py OUT.txt   (quit OHW Studio first; run from the Terminal panel)"""
import asyncio, re, sys, os
sys.path.insert(0, os.path.dirname(__file__))
import ohw

READ = 0x10
SKIP = {0x0101, 0x0102, 0x0222, 0x0609, 0x0235, 0x024c, 0x0279, 0x0282, 0x0242, 0x0301, 0x0302}

def keys():
    md = open(os.path.join(os.path.dirname(__file__), "../reference/sma-protocol/BLEKEYS.md")).read()
    out = []
    for name, hx in re.findall(r"\| `([A-Z0-9_]+)` \| `0x([0-9a-f]{4})`", md):
        k = int(hx, 16)
        if k in SKIP or k >> 8 in (0x01, 0x07) or k in (0x0000, 0xffff): continue
        out.append((k, name))
    return sorted(set(out))

async def main():
    path = sys.argv[1]
    async with ohw.Watch(verbose=False) as w:
        await w.handshake(wait_info=True)
        await asyncio.sleep(1)
        with open(path, "w") as f:
            for k, name in keys():
                while not w.q.empty(): w.q.get_nowait()
                await w.send(k, READ)
                got = []
                end = asyncio.get_event_loop().time() + 1.4
                while (left := end - asyncio.get_event_loop().time()) > 0:
                    try: kk, fl, d = await asyncio.wait_for(w.q.get(), left)
                    except asyncio.TimeoutError: break
                    if kk == k: got.append(d); end = asyncio.get_event_loop().time() + 0.5
                    if w.disconnected.is_set(): break
                line = f"{k:04x} {name:32s} " + (" | ".join(g.hex() for g in got) if got else "-")
                print(line[:160]); f.write(line + "\n"); f.flush()
                if w.disconnected.is_set():
                    print("DISCONNECTED"); f.write("DISCONNECTED\n"); return

asyncio.run(main())
