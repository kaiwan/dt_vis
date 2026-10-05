#!/usr/bin/env python3
"""dtb2fs.py -- expand a flattened device tree blob into a directory tree.

Test helper only.  Produces the same layout the kernel exposes at
/proc/device-tree (and /sys/firmware/devicetree/base): one directory per
node, one file per property holding the raw property bytes.  That lets the
fdt back-end of dt_vis be tested on a build machine, without a board.

Usage: dtb2fs.py <file.dtb> <outdir>
"""
import os
import struct
import sys

FDT_MAGIC = 0xD00DFEED
FDT_BEGIN_NODE, FDT_END_NODE, FDT_PROP, FDT_NOP, FDT_END = 1, 2, 3, 4, 9


def cstr(buf, off):
    end = buf.index(b"\0", off)
    return buf[off:end].decode("utf-8", "replace")


def main(argv):
    if len(argv) != 3:
        sys.exit(__doc__)
    blob = open(argv[1], "rb").read()
    magic, _tot, off_struct, off_strings = struct.unpack_from(">4I", blob, 0)
    if magic != FDT_MAGIC:
        sys.exit("dtb2fs: not an FDT blob (magic %#x)" % magic)

    outdir = argv[2]
    os.makedirs(outdir, exist_ok=True)
    path = [outdir]
    off = off_struct
    depth = 0

    while True:
        (tok,) = struct.unpack_from(">I", blob, off)
        off += 4
        if tok == FDT_BEGIN_NODE:
            name = cstr(blob, off)
            off += (len(name.encode()) + 4) & ~3
            if depth:                      # root maps onto outdir itself
                path.append(os.path.join(path[-1], name))
                os.makedirs(path[-1], exist_ok=True)
            depth += 1
        elif tok == FDT_END_NODE:
            depth -= 1
            if depth:
                path.pop()
        elif tok == FDT_PROP:
            dlen, nameoff = struct.unpack_from(">2I", blob, off)
            off += 8
            pname = cstr(blob, off_strings + nameoff)
            data = blob[off:off + dlen]
            off += (dlen + 3) & ~3
            with open(os.path.join(path[-1], pname), "wb") as f:
                f.write(data)
        elif tok == FDT_NOP:
            continue
        elif tok == FDT_END:
            break
        else:
            sys.exit("dtb2fs: bad token %#x at %#x" % (tok, off - 4))


if __name__ == "__main__":
    main(sys.argv)
