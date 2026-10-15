# types.py: CA::Render::Type of every class, sim vs macOS, from the type byte each Decoder constructor stores.
import re, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from show import funcs
def ctor_types(plat):
    m = {}
    for a, n, b in funcs(plat):
        k = re.match(r'CA::Render::(\w+)::\1\(CA::Render::Decoder\*', n)
        if not k: continue
        for v in re.findall(r'\+ 12\) = (\d+);', b): m.setdefault(k.group(1), set()).add(int(v))
    return m
s, mc = ctor_types("sim"), ctor_types("mac")
names = sorted(set(s) | set(mc))
for nm in names: print(f"{nm:28s} sim={sorted(s.get(nm, []))} mac={sorted(mc.get(nm, []))}")
