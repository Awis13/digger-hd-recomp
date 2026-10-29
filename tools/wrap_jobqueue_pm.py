#!/usr/bin/env python3
"""Wrap Digger HD's SPURS job-queue policy module as an SPU ELF.

The policy module is linked into EBOOT.elf as raw SPU code (3104 bytes at
0x546080), not as an embedded ELF, so the SPU image scan does not find it.
SPURS loads a policy module at local store 0xA00. Wrapped at that base, the
ELF's text segment fingerprints exactly as the runtime fingerprints the module
when the game registers its workload, so the lifted code is found.

Usage: wrap_jobqueue_pm.py <EBOOT.elf> <ps3recomp tools dir> <out.elf>
"""
import struct
import sys

PM_EA = 0x546080
PM_SIZE = 3104
PM_LS_BASE = 0xA00
PM_FINGERPRINT = 0x13E1FA9D00B5CFE0


def read_va(elf, va, size):
    phoff = struct.unpack('>Q', elf[0x20:0x28])[0]
    phnum = struct.unpack('>H', elf[0x38:0x3A])[0]
    for i in range(phnum):
        p_type, _, off, vaddr, _, filesz, _, _ = struct.unpack(
            '>IIQQQQQQ', elf[phoff + i * 56:phoff + i * 56 + 56])
        if p_type == 1 and vaddr <= va and va + size <= vaddr + filesz:
            return elf[off + va - vaddr:off + va - vaddr + size]
    raise SystemExit('policy module address is not in a loaded segment')


def main():
    eboot, tools, out = sys.argv[1:4]
    sys.path.insert(0, tools)
    from spu_program_pipeline import fnv1a64
    from wrap_spu_elf import wrap
    pm = read_va(open(eboot, 'rb').read(), PM_EA, PM_SIZE)
    if fnv1a64(pm) != PM_FINGERPRINT:
        raise SystemExit('policy module bytes differ from NPEB00121')
    open(out, 'wb').write(wrap(pm, base=PM_LS_BASE, entry=PM_LS_BASE))


if __name__ == '__main__':
    main()
