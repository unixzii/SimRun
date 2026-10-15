# show.py <sim|mac> <substring...>: print decompiled functions whose demangled name contains every substring.
# Reads $RE_WORK/<sim|mac>/qc.c (default ./work), written by ida_dump.py.
import sys, re, os
d = os.environ.get("RE_WORK", "work")
def funcs(plat):
    src = open(f"{d}/{plat}/qc.c").read()
    parts = re.split(r'(?m)^// ([0-9a-f]+) (.*)$', src)
    return [(parts[i], parts[i+1].replace(' *', '*').replace(' &', '&'), parts[i+2]) for i in range(1, len(parts), 3)]
if __name__ == "__main__":
    for a, n, b in funcs(sys.argv[1]):
        if all(s in n for s in sys.argv[2:]):
            print("//", a, n); print(b.strip()); print()
