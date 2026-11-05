"""Decode the SMA BleDeviceInfo push (IDENTITY 0x0301 UPDATE from the watch).
Field order generated from com.szabh.smable3.entity.BleDeviceInfo.decode()."""
import re, sys

def fields(java_path):
    """Every line with a read* call is one field, in order. A read into a local is named by
    the next `this.mX =` assignment without a read."""
    out, pending = [], []
    for line in open(java_path):
        t = None
        if "readInt32" in line: t = "i32"
        elif "readBytesUtil" in line: t = "bytes0"
        elif "readStringUtil" in line: t = "str0"
        elif "readUInt16" in line: t = "u16"
        elif "readInt8" in line or "readUInt8" in line: t = "u8"
        m = re.search(r"this\.(m\w+) =", line)
        if t:
            if m: out.append([m.group(1), t])
            else: pending.append(len(out)); out.append(["?", t])
        elif m and pending:
            out[pending.pop(0)][0] = m.group(1)
    return out

def decode(data: bytes, spec):
    i, res = 0, {}
    for name, t in spec:
        if i >= len(data): res[name] = None; continue
        if t == "i32": res[name] = data[i:i+4].hex(); i += 4
        elif t in ("bytes0", "str0"):
            j = data.index(0, i); raw = data[i:j]; i = j + 1
            res[name] = raw.hex() if t == "bytes0" else raw.decode(errors="replace")
        elif t == "u16": res[name] = int.from_bytes(data[i:i+2], "big"); i += 2
        else: res[name] = data[i]; i += 1
    return res, len(data) - i

if __name__ == "__main__":
    spec = fields(sys.argv[1]); data = bytes.fromhex(sys.argv[2])
    res, rest = decode(data, spec)
    for k, v in res.items():
        if v not in (0, None) or k in ("mSupportWatchface2", "mWatchFaceType", "mSupportJLTransport", "mSupportNewTransportMode"):
            print(f"{k:40} {v}")
    print("unparsed trailing bytes:", rest)
