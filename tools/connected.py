"""Ask CoreBluetooth for already-connected peripherals exposing common watch service UUIDs."""
import time
from Foundation import NSObject, NSRunLoop, NSDate
from CoreBluetooth import CBCentralManager, CBUUID

UUIDS = ["180A", "180F", "1800", "1801", "180D", "AE00", "AE30", "FEE7", "FFF0", "FFE0",
         "6E400001-B5A3-F393-E0A9-E50E24DCCA9E", "FE59", "D0FF", "FD00", "190E", "FEEA"]

class D(NSObject):
    def centralManagerDidUpdateState_(self, m):
        self.ready = True

d = D.alloc().init(); d.ready = False
m = CBCentralManager.alloc().initWithDelegate_queue_(d, None)
end = time.time() + 5
while not d.ready and time.time() < end:
    NSRunLoop.currentRunLoop().runUntilDate_(NSDate.dateWithTimeIntervalSinceNow_(0.1))
print("state", m.state())
seen = {}
for u in UUIDS:
    for p in m.retrieveConnectedPeripheralsWithServices_([CBUUID.UUIDWithString_(u)]):
        seen.setdefault(str(p.identifier()), (p.name(), []))[1].append(u)
for k, (n, us) in seen.items():
    print(k, n, us)
if not seen: print("no connected BLE peripherals matched")
