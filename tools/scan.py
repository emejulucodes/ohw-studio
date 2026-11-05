"""Scan for BLE advertisements and print anything that looks like the watch."""
import asyncio, sys
from bleak import BleakScanner

async def main(t=12):
    found = await BleakScanner.discover(timeout=t, return_adv=True)
    for addr, (dev, adv) in sorted(found.items(), key=lambda kv: -kv[1][1].rssi):
        name = adv.local_name or dev.name or ""
        flag = "  <<<" if "OHW" in name.upper() else ""
        print(f"{addr} rssi={adv.rssi} name={name!r}{flag}")
        if flag or "-v" in sys.argv:
            print("   services:", adv.service_uuids)
            print("   mfr:", {hex(k): v.hex() for k, v in adv.manufacturer_data.items()})
            print("   svcdata:", {k: v.hex() for k, v in adv.service_data.items()})

asyncio.run(main())
