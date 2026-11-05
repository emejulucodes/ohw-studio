"""Connect to OHW-11, dump all services/characteristics, read readable values."""
import asyncio, sys
from bleak import BleakScanner, BleakClient

NAME = "OHW-11"

async def main():
    dev = await BleakScanner.find_device_by_name(NAME, timeout=15)
    if not dev:
        print("watch not found"); return
    print("found", dev.address)
    async with BleakClient(dev) as c:
        print("connected, mtu", c.mtu_size)
        for s in c.services:
            print(f"\nSERVICE {s.uuid}  ({s.description})")
            for ch in s.characteristics:
                line = f"  CHAR {ch.uuid} [{','.join(ch.properties)}] h={ch.handle} ({ch.description})"
                if "read" in ch.properties:
                    try:
                        v = await c.read_gatt_char(ch)
                        line += f"\n      = {v.hex()}  {v!r}"
                    except Exception as e:
                        line += f"\n      read err: {e}"
                print(line)
                for d in ch.descriptors:
                    print(f"     DESC {d.uuid} h={d.handle}")

asyncio.run(main())
