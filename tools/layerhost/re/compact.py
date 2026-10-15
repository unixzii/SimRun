# compact.py <sim|mac> <name substr>: a decompiled encoder reduced to its writes (NORM=1 also renames variables,
# for diffing the two platforms' versions).
import re, sys, os
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from show import funcs
for a, n, b in funcs(sys.argv[1]):
    if not all(s in n for s in sys.argv[2:]): continue
    print("//", n)
    enc = re.search(r'CA::Render::Encoder \*(\w+)\)', b.split('\n')[0] + b)
    e = enc.group(1) if enc else 'a2'
    lines = b.split('\n')
    out = []
    skip = 0
    for i, l in enumerate(lines):
        s = l.strip()
        if re.match(r'^[_a-zA-Z][\w\s\*:<>,]*\b\w+(\[\d+\])?; //', s): continue   # declarations
        if not s or s in ('{', '}'): continue
        s = s.replace(f'*((_QWORD *){e} + 4)', 'CUR').replace(f'*((_QWORD *){e} + 5)', 'END')
        s = re.sub(rf'\*\(\((\w+) \*\*\){e} \+ 4\)', 'CUR', s)
        if 'grow(' in s or re.match(r'^if \( \(unsigned __int64\)\(.*\) > (END|\*\(\(_QWORD \*\)\w+ \+ 5\))', s) or re.match(r'^if \( \w+ \+ \d+ > \w+ \)$', s): continue
        if re.match(r'^\w+ = CUR;$', s) or re.match(r'^\w+ = END;$', s) or re.match(r'^\w+ = \*\(\(_QWORD \*\)\w+ \+ [45]\);$', s): continue
        if 'encode_sanity_check' in s or '__break' in s or '0x4000000000000000' in s: continue
        if os.environ.get('NORM'):
            s = re.sub(r'\b[va]\d+\b', 'v', s); s = re.sub(r'\((__int64|_QWORD \*|_DWORD \*|unsigned __int64|const CA::Render::[\w:]+ \*\*?|CA::Render::[\w:]+ \*\*?)\)', '', s); s = re.sub(r'\b(this|object_handle)\b', 'this', s)
            if i < 3: continue
        out.append(s)
    print("\n".join(out)); print()
