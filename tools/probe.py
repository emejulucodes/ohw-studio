"""Listen on both notify channels; optionally send read-only probes.
usage: probe.py [listen_seconds] [--rcsp-info] [--nus HEX ...]"""
import asyncio, sys, time
from bleak import BleakScanner, BleakClient

NUS_RX = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"; NUS_TX = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"
AE_W = "0000ae01-0000-1000-8000-00805f9b34fb";   AE_N = "0000ae02-0000-1000-8000-00805f9b34fb"
t0 = time.time()

def rcsp(opcode, sn, params=b"", cmd=True, resp=True):
    flag = (0x80 if cmd else 0) | (0x40 if resp else 0)
    body = bytes([sn]) + params
    return b"\xfe\xdc\xba" + bytes([flag, opcode]) + len(body).to_bytes(2, "big") + body + b"\xef"

def log(tag):
    def h(_, data: bytearray):
        print(f"[{time.time()-t0:6.2f}] {tag} <- {bytes(data).hex()}  {bytes(data)!r}", flush=True)
    return h

async def main():
    args = sys.argv[1:]
    secs = float(args[0]) if args and args[0][0].isdigit() else 10
    dev = await BleakScanner.find_device_by_name("OHW-11", timeout=15)
    if not dev: print("not found"); return
    async with BleakClient(dev) as c:
        await c.start_notify(NUS_TX, log("NUS"))
        await c.start_notify(AE_N, log("AE02"))
        print("subscribed")
        if "--rcsp-info" in args:
            p = rcsp(0x03, 0x01, b"\xff\xff\xff\xff")
            print("AE01 ->", p.hex()); await c.write_gatt_char(AE_W, p, response=False)
        if "--nus" in args:
            for h in args[args.index("--nus")+1:]:
                b = bytes.fromhex(h); print("NUS ->", b.hex())
                await c.write_gatt_char(NUS_RX, b, response=True); await asyncio.sleep(1.5)
        await asyncio.sleep(secs)

asyncio.run(main())
