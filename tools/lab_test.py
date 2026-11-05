"""Write-test of features CO FIT has but OHW Studio doesn't yet: alarm, calendar event, world clock, stock.
Each list is cleared (DELETE 255) first, then one item created, then read back.
usage: python lab_test.py   (quit OHW Studio first; run from the Terminal panel)"""
import asyncio, struct, sys, os
from datetime import datetime, timedelta
sys.path.insert(0, os.path.dirname(__file__))
import ohw

UPDATE, READ, CREATE, DELETE = 0x00, 0x10, 0x20, 0x30

def fix(s, n): b = s.encode()[: n - 1]; return b + b"\0" * (n - len(b))

def alarm(i, t, tag, repeat=0, on=1):
    return bytes([i, (on << 7) | repeat, t.year - 2000, t.month, t.day, t.hour, t.minute]) + fix(tag, 21)

def schedule(i, t, title, body, advance=0):
    return bytes([i, t.year - 2000, t.month, t.day, t.hour, t.minute]) + struct.pack(">H", advance) + fix(title, 32) + body.encode()[:250]

def world_clock(i, quarter_hours, city, local=0):
    return bytes([(local << 7) | i, quarter_hours & 0xff]) + b"\0\0" + fix(city, 62) + b"\0\0"

def stock(i, code, price, change, pct, cap=0.0):
    return bytes([i, 0, 0x22, 0x02]) + fix(code, 62) + b"\0\0" + struct.pack("<ffff", price, change, pct, cap)

async def main():
    async with ohw.Watch(verbose=True) as w:
        await w.handshake(wait_info=True)
        await asyncio.sleep(1)
        now = datetime.now()
        tests = [
            (0x0210, "ALARM", alarm(0, now + timedelta(minutes=2), "OHW Studio test")),
            (0x0403, "SCHEDULE", schedule(0, now + timedelta(minutes=3), "Studio test event", "Sent from your Mac")),
            (0x0407, "WORLD_CLOCK", world_clock(0, 0, "London")),
            (0x0408, "STOCK", stock(0, "AAPL", 231.45, 2.31, 1.01)),
        ]
        for key, name, data in tests:
            print(f"\n=== {name}")
            await w.send(key, DELETE, b"\xff"); print("  delete-all ->", await w.wait(key, 3))
            await w.send(key, CREATE, data);   print("  create ->", await w.wait(key, 3))
            await w.send(key, READ);           print("  read ->", (await w.collect(key, 4, 1.0)).hex())
        print(f"\nALARM set for {(now + timedelta(minutes=2)):%H:%M}, calendar event at {(now + timedelta(minutes=3)):%H:%M}.")
        print("Check the watch: alarm list, calendar/schedule, world clock and stocks apps.")

asyncio.run(main())
