# IDA script: decompile functions whose demangled name matches $PAT (regex) into $OUT; with $LIST, only write names.
#   PAT=... OUT=work/sim/qc.c idat -A -Sida_dump.py work/sim/qc.i64
import idaapi, idautils, idc, ida_hexrays, ida_auto, ida_name, os, re
ida_auto.auto_wait()
rx = re.compile(os.environ["PAT"])
with open(os.environ["OUT"], "w") as f:
    for ea in idautils.Functions():
        n = idc.get_func_name(ea)
        dn = ida_name.demangle_name(n, 0) or n
        if not rx.search(dn): continue
        if os.environ.get("LIST"):
            f.write("%x %s\n" % (ea, dn)); continue
        try: f.write("// %x %s\n%s\n\n" % (ea, dn, ida_hexrays.decompile(ea)))
        except Exception as e: f.write("// %x %s FAILED %s\n" % (ea, dn, e))
idc.qexit(0)
