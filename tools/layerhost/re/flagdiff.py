# flagdiff.py sim.txt mac.txt: which flag bits each CALayer property sets on each platform (flagprobe output).
import sys
def load(p):
    return {l.split('\t')[0]: bytes.fromhex(l.split('\t')[1].strip()) for l in open(p) if '\t' in l}
s, m = load(sys.argv[1]), load(sys.argv[2])
def bits(a, b):
    out = []
    for i in range(len(a)):
        x = a[i] ^ b[i]
        for k in range(8):
            if x >> k & 1: out.append(f"{'+' if b[i]>>k&1 else '-'}{(36+i)}.{k}")
    return out
print("default sim", s["default"].hex(), " mac", m["default"].hex())
for k in sorted(set(s) | set(m)):
    if k == "default": continue
    bs = bits(s["default"], s[k]) if k in s else ["(n/a)"]
    bm = bits(m["default"], m[k]) if k in m else ["(n/a)"]
    if bs or bm: print(f"{k:42s} sim {' '.join(bs):18s} mac {' '.join(bm)}")
