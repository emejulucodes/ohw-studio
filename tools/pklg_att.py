"""Extract ATT writes/notifications from an Apple PacketLogger .pklg capture.
usage: python pklg_att.py capture.pklg [--handles 6,8,130,132]"""
import struct, sys, datetime

ATT_OPS = {0x12: "WRITE_REQ", 0x52: "WRITE_CMD", 0x1B: "NOTIFY", 0x1D: "INDICATE", 0x0B: "READ_RSP", 0x0A: "READ_REQ"}

def records(buf):
    i = 0
    # header length is big-endian in classic pklg, little-endian in newer iOS traces
    le = struct.unpack_from("<I", buf, 0)[0] < struct.unpack_from(">I", buf, 0)[0]
    e = "<" if le else ">"
    while i + 13 <= len(buf):
        ln, sec, usec = struct.unpack_from(e + "III", buf, i)
        if ln < 9 or i + 4 + ln > len(buf): break
        typ = buf[i + 12]; data = buf[i + 13:i + 4 + ln]
        yield sec + usec / 1e6, typ, data
        i += 4 + ln

def main():
    path = sys.argv[1]
    want = None
    if "--handles" in sys.argv:
        want = {int(x, 0) for x in sys.argv[sys.argv.index("--handles") + 1].split(",")}
    buf = open(path, "rb").read()
    partial = {}
    for ts, typ, d in records(buf):
        if typ not in (0x02, 0x03) or len(d) < 4: continue   # ACL sent / received
        hdl, alen = struct.unpack_from("<HH", d, 0)
        conn, pb = hdl & 0x0FFF, (hdl >> 12) & 0x3
        payload = d[4:4 + alen]
        if pb == 0x1 and conn in partial:              # continuation fragment
            partial[conn] += payload
        else:
            partial[conn] = payload
        l2 = partial[conn]
        if len(l2) < 4: continue
        llen, cid = struct.unpack_from("<HH", l2, 0)
        if len(l2) < 4 + llen: continue
        del partial[conn]
        if cid != 0x0004: continue
        att = l2[4:4 + llen]
        op = att[0]
        if op not in ATT_OPS or len(att) < 3: continue
        h = struct.unpack_from("<H", att, 1)[0] if op != 0x0B else None
        if want and h not in want: continue
        val = att[3:] if op != 0x0B else att[1:]
        t = datetime.datetime.fromtimestamp(ts).strftime("%H:%M:%S.%f")[:-3]
        direction = "PHONE->WATCH" if typ == 0x02 else "WATCH->PHONE"
        print(f"{t} {direction} {ATT_OPS[op]:9} h=0x{(h or 0):04x} {val.hex()}")

main()
