#!/usr/bin/env python3
"""
Emulation test for the Tempest 4000 launcher mode loop.

Runs the game's real x86 code for the mode-filter loop (from the return of
IDXGIOutput::GetDisplayModeList to the listbox fill) under unicorn, against
synthetic DXGI mode lists, and reports what would appear in the launcher listbox.
Works on original and patched executables, at any load base (ASLR simulation).

    pip install pefile capstone unicorn
    python3 tools/emu_test.py path/to/Tempest4000.exe [--base 0x10000000]

Exit status is non-zero if a patched exe fails to list 3840x2160@60 in the
"4K TV" scenario, so this can run in CI against a locally-patched copy.
"""
import os, sys, math, struct
sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), '..'))
import t4k_resfix as fix
import pefile
from unicorn import Uc, UC_ARCH_X86, UC_MODE_32, UC_HOOK_CODE
from unicorn.x86_const import *

def mode(w, h, num, den, fmt=28, scan=1, scale=0):
    return struct.pack('<7I', w, h, num, den, fmt, scan, scale)

def run(exe, modes, desktop=(3840, 2160, 60, 1), prefs=None, base=0x400000):
    R = fix.locate_sites(exe)
    pe = pefile.PE(exe)
    delta = base - pe.OPTIONAL_HEADER.ImageBase
    if delta:
        pe.relocate_image(base)
    img = bytes(pe.get_memory_mapped_image())
    A = lambda va: va + delta          # image address at the chosen base
    uc = Uc(UC_ARCH_X86, UC_MODE_32)
    uc.mem_map(base, ((len(img) + 0xfff) & ~0xfff) + 0x100000)
    uc.mem_write(base, img)
    STACK = 0x7f000000; uc.mem_map(STACK, 0x200000); F = STACK + 0x100000
    HEAP = 0x30000000; uc.mem_map(HEAP, 0x400000)
    src, dst, desired = HEAP, HEAP + 0x100000, HEAP + 0x200000
    count = len(modes)
    uc.mem_write(src, b''.join(modes)); uc.mem_write(dst, b'\0' * (count * 28))
    desk = mode(*desktop); want = mode(*prefs) if prefs else desk
    uc.mem_write(desired, want + desk + b'\0' * 8)      # +0x00 desired (prefs/desktop), +0x1c desktop copy
    uc.mem_write(A(R['g_modearray']), struct.pack('<I', src))
    uc.mem_write(A(R['g_outarray']), struct.pack('<I', dst))
    uc.mem_write(A(R['g_desired']), struct.pack('<I', desired))
    uc.mem_write(F + 0x1c, struct.pack('<I', count))       # mode count from GetDisplayModeList
    uc.mem_write(F + 0x28, struct.pack('<i', -1))          # best-match index
    uc.mem_write(F + 0x34, struct.pack('<I', 0x4fffffff))  # best-match distance
    uc.reg_write(UC_X86_REG_ESP, F); uc.reg_write(UC_X86_REG_EBP, F + 0x10cb0)

    def hook(uc, addr, size, _):
        if addr == A(R['call_floor']):          # CRT floor(double) -> emulate, resume after the fstp
            esp = uc.reg_read(UC_X86_REG_ESP)
            x = struct.unpack('<d', uc.mem_read(esp, 8))[0]
            uc.mem_write(esp + 0x40, struct.pack('<d', math.floor(x)))
            uc.reg_write(UC_X86_REG_EIP, A(R['after_floor_store']))
        elif addr == A(R['call_sprintf']):      # swprintf_s(buf, 0x100, fmt, w, h, hz)
            esp = uc.reg_read(UC_X86_REG_ESP)
            buf, cnt, fmt, w, h, hz = struct.unpack('<6I', uc.mem_read(esp, 24))
            s = "%u x %u @%-d Hz" % (w, h, hz)
            uc.mem_write(buf, s.encode('utf-16-le') + b'\0\0')
            uc.reg_write(UC_X86_REG_EAX, len(s)); uc.reg_write(UC_X86_REG_EIP, A(R['after_sprintf']))
    uc.hook_add(UC_HOOK_CODE, hook)
    uc.emu_start(A(R['loop_start']), A(R['loop_end']), count=50_000_000)
    assert uc.reg_read(UC_X86_REG_EIP) == A(R['loop_end']), "loop did not complete"
    accepted = struct.unpack('<I', uc.mem_read(F + 0x10, 4))[0]
    best = struct.unpack('<i', uc.mem_read(F + 0x28, 4))[0]
    strings = [uc.mem_read(F + 0xca8 + i * 0x100, 0x100).decode('utf-16-le', 'replace').split('\0')[0]
               for i in range(min(accepted, 256))]
    return accepted, best, strings

def dxgi_list(resolutions, refreshes, duplicate=True):
    """Ascending by width/height/refresh; NVIDIA typically reports each mode twice."""
    out = []
    for (w, h) in sorted(resolutions):
        for (num, den) in sorted(refreshes, key=lambda r: r[0] / r[1]):
            out.append(mode(w, h, num, den, scan=0))
            if duplicate: out.append(mode(w, h, num, den, scan=1))
    return out

RES_4K_TV = [(640,480),(720,480),(720,576),(800,600),(848,480),(1024,768),(1152,864),(1176,664),
             (1280,720),(1280,768),(1280,800),(1280,960),(1280,1024),(1360,768),(1366,768),(1440,900),
             (1600,900),(1600,1024),(1680,1050),(1768,992),(1920,1080),(1920,1200),(2560,1440),(2560,1600),
             (3840,2160)]
REFRESH_144 = [(23976,1000),(24,1),(25,1),(29970,1000),(30,1),(50,1),(59940,1000),(60,1),(100,1),
               (119880,1000),(120,1),(143988,1000),(144,1)]

def main():
    args = [a for a in sys.argv[1:] if not a.startswith('--')]
    base = 0x400000
    if '--base' in sys.argv:
        base = int(sys.argv[sys.argv.index('--base') + 1], 16)
    exe = args[0]
    data = open(exe, 'rb').read()
    patched = fix.sha256(data) not in fix.KNOWN_BUILDS
    print("exe: %s  (%s)  base %#x" % (exe, "patched/unknown" if patched else "original", base))
    ok = True
    scen = [("4K/144 TV, 25 res x 13 Hz, duplicated", dxgi_list(RES_4K_TV, REFRESH_144), (3840,2160,60,1), None),
            ("same, prefs = 3840x2160@60",           dxgi_list(RES_4K_TV, REFRESH_144), (3840,2160,60,1), (3840,2160,60,1)),
            ("stress: 70 res x 13 Hz, duplicated",   dxgi_list(sorted(set(RES_4K_TV) | {(320+8*i, (320+8*i)*9//16//8*8) for i in range(0, 440, 10)} | {(5120,2880),(7680,4320)}), REFRESH_144), (3840,2160,60,1), None),
            ("1366x768 laptop, 5 modes",             dxgi_list([(640,480),(800,600),(1024,768),(1280,720),(1366,768)], [(60,1)], False), (1366,768,60,1), None)]
    for name, modes, desk, prefs in scen:
        accepted, best, strings = run(exe, modes, desk, prefs, base)
        has4k = any(s.startswith("3840 x 2160 @60 ") for s in strings)
        sel = strings[best] if 0 <= best < len(strings) else None
        print("  %-42s src=%4d accepted=%3d 4K@60=%-5s default=%s" % (name, len(modes), accepted, has4k, sel))
        if patched and desk[0] >= 3840 and not has4k:
            ok = False
        if accepted == 0:
            ok = False
    print("RESULT:", "PASS" if ok else "FAIL")
    return 0 if ok else 1

if __name__ == '__main__':
    sys.exit(main())
