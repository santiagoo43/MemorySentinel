#!/usr/bin/env python3
"""Read-only macOS app resource measurement; no memory stress or process signals."""
import ctypes
import json
import subprocess
import sys
import time

class Usage(ctypes.Structure):
    _fields_ = [("uuid", ctypes.c_ubyte * 16)] + [
        (name, ctypes.c_uint64) for name in (
            "user", "system", "idle", "interrupt", "pageins", "wired", "rss",
            "footprint", "started", "exited")
    ]

pid = int(sys.argv[1])
duration = int(sys.argv[2]) if len(sys.argv) > 2 else 60
lib = ctypes.CDLL("/usr/lib/libproc.dylib")
lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
lib.proc_pid_rusage.restype = ctypes.c_int

def cpu_seconds():
    raw = subprocess.check_output(["ps", "-p", str(pid), "-o", "time="], text=True).strip()
    parts = raw.split(":")
    return sum(float(part) * 60 ** i for i, part in enumerate(reversed(parts)))

start = time.monotonic()
cpu_start = cpu_seconds()
rows = []
while True:
    usage = Usage()
    if lib.proc_pid_rusage(pid, 0, ctypes.byref(usage)) != 0:
        raise RuntimeError("Process exited or resource usage unavailable")
    rows.append({"elapsed_s": round(time.monotonic() - start, 2),
                 "footprint_mib": round(usage.footprint / 1048576, 2),
                 "rss_mib": round(usage.rss / 1048576, 2)})
    if time.monotonic() - start >= duration:
        break
    time.sleep(min(5, max(0.01, duration - (time.monotonic() - start))))
elapsed = time.monotonic() - start
print(json.dumps({"pid": pid, "duration_s": round(elapsed, 2),
                  "cpu_percent_one_core": round((cpu_seconds() - cpu_start) / elapsed * 100, 3),
                  "peak_footprint_mib": max(r["footprint_mib"] for r in rows),
                  "peak_rss_mib": max(r["rss_mib"] for r in rows), "samples": rows}, indent=2))
