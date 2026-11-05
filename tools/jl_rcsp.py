"""JieLi RCSP channel (AE01 write / AE02 notify): authenticate, then query.
usage: python jl_rcsp.py [info]   — run from the Terminal panel, OHW Studio quit."""
import asyncio, sys, os, struct, time
sys.path.insert(0, os.path.dirname(__file__))
import ohw, jl_auth

AE01 = "0000ae01-0000-1000-8000-00805f9b34fb"
AE02 = "0000ae02-0000-1000-8000-00805f9b34fb"

class Rcsp:
    def __init__(self, w): self.w = w; self.raw = asyncio.Queue(); self.pk = asyncio.Queue(); self.buf = bytearray(); self.sn = 0
    def _on(self, _, d):
        d = bytes(d)
        if not d.startswith(b"\xfe\xdc\xba") and not self.buf:
            print(f"  <~ raw {d.hex()}"); self.raw.put_nowait(d); return
        self.buf += d
        while True:
            i = self.buf.find(b"\xfe\xdc\xba")
            if i < 0 or len(self.buf) < i + 7: return
            n = struct.unpack_from(">H", self.buf, i + 5)[0]
            if len(self.buf) < i + 8 + n: return
            fl, op = self.buf[i + 3], self.buf[i + 4]; body = bytes(self.buf[i + 7:i + 7 + n]); del self.buf[:i + 8 + n]
            print(f"  <~ {'cmd' if fl & 0x80 else 'rsp'} op={op} ({op:#04x}) fl={fl:02x} {len(body)}B {body[:96].hex()}{'…' if len(body) > 96 else ''}")
            self.pk.put_nowait((fl, op, body))
    async def start(self): await self.w.c.start_notify(AE02, self._on)
    async def write(self, b):
        mtu = max(20, self.w.c.mtu_size - 3)
        for i in range(0, len(b), mtu): await self.w.c.write_gatt_char(AE01, b[i:i + mtu], response=False)
    async def raw_wait(self, t=4):
        try: return await asyncio.wait_for(self.raw.get(), t)
        except asyncio.TimeoutError: return None
    async def auth(self):
        rnd = b"\x00" + os.urandom(16)
        await self.write(rnd)
        r = await self.raw_wait()
        if not r: print("auth: no answer"); return False
        mine = jl_auth.respond(rnd)
        print("auth: device proof", "MATCHES" if r == mine else f"differs (ours {mine.hex()})")
        await self.write(b"\x02pass")
        ch = await self.raw_wait()
        if not ch or len(ch) != 17: print("auth: no challenge", ch); return False
        await self.write(jl_auth.respond(ch))
        ok = await self.raw_wait()
        print("auth:", ok)
        return ok == b"\x02pass"
    async def cmd(self, op, params=b"", resp=True, t=4):
        self.sn = (self.sn + 1) & 0xff
        body = bytes([self.sn]) + params
        f = b"\xfe\xdc\xba" + bytes([0x80 | (0x40 if resp else 0), op]) + struct.pack(">H", len(body)) + body + b"\xef"
        print(f"  ~> op={op} ({op:#04x}) {params.hex()}")
        await self.write(f)
        if not resp: return None
        end = time.monotonic() + t
        while (left := end - time.monotonic()) > 0:
            try: fl, o, b = await asyncio.wait_for(self.pk.get(), left)
            except asyncio.TimeoutError: break
            if o == op and not fl & 0x80: return b
        return None

async def main():
    async with ohw.Watch(verbose=False) as w:
        r = Rcsp(w); await r.start(); await asyncio.sleep(0.5)
        if not await r.auth(): return
        mode = sys.argv[1] if len(sys.argv) > 1 else "info"
        if mode == "info":
            info = await r.cmd(3, b"\xff\xff\xff\xff\x00")
            fm = await r.cmd(2)
        elif mode == "explore":   # read-only queries
            steps = [
                ("EXTERNAL_FLASH_MSG", 214, b""),
                ("DEVICE_CONFIG_INFO", 217, b""),
                ("READ_ERROR_MSG", 41, b""),
                ("CONNECTED_PHONE_BT", 49, b""),
                ("FLASH READ 0+256", 26, bytes([1, 0]) + struct.pack(">IH", 0, 256)),
                ("FILE_BROWSE root", 12, bytes([0, 20]) + struct.pack(">HI", 1, 0) + struct.pack(">H", 0)),
            ] + [(f"SYS_INFO fn {fn:#04x}", 7, bytes([fn]) + b"\xff\xff\xff\xff") for fn in (0xff, 0, 1, 2, 3, 4, 5, 6, 0x16)]
            for name, op, prm in steps:
                print(f"\n== {name}")
                b = await r.cmd(op, prm, t=3)
                if b is not None: print(f"   reply status={b[0]} sn={b[1]} data[{len(b)-2}]={b[2:].hex()}  {b[2:].decode('latin1')!r}"[:600])
                else: print("   (no reply)")
        await asyncio.sleep(2)

if __name__ == "__main__":
    asyncio.run(main())
