"""JieLi RCSP authentication (libjl_auth.so): Bluetooth E1 (SAFER+) with a fixed key and address."""
EXP = [pow(45, i, 257) % 256 for i in range(256)]
LOG = [0] * 256
for i, v in enumerate(EXP): LOG[v] = i
XORP = {0, 3, 4, 7, 8, 11, 12, 15}
PERM = [8, 11, 12, 15, 2, 1, 6, 5, 10, 9, 14, 13, 0, 7, 4, 3]
BIAS = {p: [EXP[EXP[(17 * p + i + 1) % 256]] for i in range(16)] for p in range(2, 18)}

def _keys(k):
    k = list(k) + [0]
    for b in k[:16]: k[16] ^= b
    out = [k[:16]]
    for p in range(2, 18):
        k = [((b << 3) | (b >> 5)) & 0xff for b in k]
        out.append([(k[(p - 1 + i) % 17] + BIAS[p][i]) & 0xff for i in range(16)])
    return out

def _ar(key, data, prime=False):
    ks = _keys(key); x = list(data); orig = list(data)
    for r in range(8):
        if prime and r == 2:
            x = [(x[i] ^ orig[i]) if i in XORP else (x[i] + orig[i]) & 0xff for i in range(16)]
        a, b = ks[2 * r], ks[2 * r + 1]
        x = [(x[i] ^ a[i]) if i in XORP else (x[i] + a[i]) & 0xff for i in range(16)]
        x = [EXP[x[i]] if i in XORP else LOG[x[i]] for i in range(16)]
        x = [(x[i] + b[i]) & 0xff if i in XORP else (x[i] ^ b[i]) for i in range(16)]
        for layer in range(4):
            y = []
            for j in range(0, 16, 2):
                y += [(2 * x[j] + x[j + 1]) & 0xff, (x[j] + x[j + 1]) & 0xff]
            x = [y[PERM[i]] for i in range(16)] if layer < 3 else y
    k = ks[16]
    return [(x[i] ^ k[i]) if i in XORP else (x[i] + k[i]) & 0xff for i in range(16)]

OFF = [(233, 1), (229, 0), (223, 1), (193, 0), (179, 1), (167, 0), (149, 1), (131, 0),
       (233, 0), (229, 1), (223, 0), (193, 1), (179, 0), (167, 1), (149, 0), (131, 1)]  # (value, add?)

def e1(key, rand, addr):
    kt = [(key[i] + v) & 0xff if add else key[i] ^ v for i, (v, add) in enumerate(OFF)]
    t = _ar(key, rand)
    t = [t[i] ^ rand[i] for i in range(16)]
    t = [(t[i] + addr[i % 6]) & 0xff for i in range(16)]
    return bytes(_ar(kt, t, prime=True))

KEY = bytes.fromhex("06775f87918dd423005df1d8cf0c142b")
ADDR = bytes.fromhex("112233332211")

def respond(challenge17: bytes) -> bytes:
    """Answer the device's [0x00]+16 challenge."""
    return b"\x01" + e1(KEY, challenge17[1:17], ADDR)

if __name__ == "__main__":
    print("B2", bytes(BIAS[2]).hex(), "(expect 4697b1baa3b7100ac537b3c95a28ac64)")
    print(respond(b"\x00" + bytes(range(16))).hex())
