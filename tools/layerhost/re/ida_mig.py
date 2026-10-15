# IDA script: dump the CARenderServices MIG subsystem table (request id -> server stub) into $OUT. On macOS's
# arm64e cache the stub pointers are stored as offsets from 0x180000000.
import idaapi, idautils, idc, ida_auto, ida_name, ida_bytes, os
ida_auto.auto_wait()
out = open(os.environ["OUT"], "w")
for ea, name in idautils.Names():
    if "CARenderServices_subsystem" not in name: continue
    start = ida_bytes.get_dword(ea + 8); end = ida_bytes.get_dword(ea + 12)
    out.write("# %s at %x: %d..%d\n" % (name, ea, start, end))
    base = ea + 32   # server(8) start(4) end(4) maxsize(4) pad(4) reserved(8) -> routines
    for i in range(end - start):
        r = base + i * 40
        impl = ida_bytes.get_qword(r) & 0xFFFFFFFFFFFF; stub = ida_bytes.get_qword(r + 8) & 0xFFFFFFFFFFFF
        if stub and stub < 0x100000000: stub += 0x180000000
        n = idc.get_func_name(stub) or ("%x" % stub)
        out.write("%d %s\n" % (start + i, ida_name.demangle_name(n, 0) or n))
idc.qexit(0)
