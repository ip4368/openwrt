#!/usr/bin/env python3
# Wrap a bare U-Boot FIT into the Qualcomm ELF/MBN 3-program-header container that
# the Linksys MBE7000 / MBE70 vendor CBT U-Boot `bootipq` loads (it parses the ELF
# program headers, loads the PT_LOAD segment to 0x44000000, then bootm's the FIT).
#
# Reproduces the stock MBE7000 kernel layout (verified via readelf on 0:HLOS):
#   ELF32 LE, Type=EXEC, e_machine=3 (EM_386, Qualcomm's dummy), 3 phdrs:
#     ph0 NULL off 0x0000 filesz 0x0094              (MBN metadata header)
#     ph1 NULL off 0x1000 filesz 0x14b8 memsz 0x14b8 (hash/sig segment)
#     ph2 LOAD off 0x3000 vaddr=paddr 0x44000000  filesz=memsz=<FIT>  RW align 0x1000
#
# Boot enforces only crc32+sha1 on the FIT itself (no RSA / no MBN-hash check on
# this unenforced boot path), so ph0/ph1 are emitted structurally but zero-filled.
#
# Usage: mbn-wrap.py <in.fit> <out.mbn>

import struct, sys

FIT_OFF, LOAD_ADDR = 0x3000, 0x44000000
PH1_OFF, PH1_SIZE, PH0_SIZE = 0x1000, 0x14b8, 0x0094

def main():
    if len(sys.argv) != 3:
        sys.exit("usage: mbn-wrap.py <in.fit> <out.mbn>")
    fit = open(sys.argv[1], "rb").read()
    if fit[:4] != b"\xd0\x0d\xfe\xed":
        sys.exit("mbn-wrap: input is not a FIT (missing d00dfeed magic)")
    n = len(fit)

    ehdr = (b"\x7fELF" + bytes([1, 1, 1, 0]) + b"\x00" * 8 +
            struct.pack("<HHIIIIIHHHHHH",
                        2, 3, 1, 0, 52, 0, 0, 52, 32, 3, 0, 0, 0))

    def ph(t, off, va, pa, fsz, msz, fl, al):
        return struct.pack("<IIIIIIII", t, off, va, pa, fsz, msz, fl, al)

    out = bytearray(FIT_OFF + n)
    out[0:len(ehdr)] = ehdr
    out[52:52 + 32]  = ph(0, 0x0,     0, 0,                 PH0_SIZE, 0,        0, 0)
    out[84:84 + 32]  = ph(0, PH1_OFF, 0, 0,                 PH1_SIZE, PH1_SIZE, 0, 0x1000)
    out[116:116 + 32]= ph(1, FIT_OFF, LOAD_ADDR, LOAD_ADDR, n,        n,        6, 0x1000)
    out[FIT_OFF:FIT_OFF + n] = fit
    open(sys.argv[2], "wb").write(out)

if __name__ == "__main__":
    main()
