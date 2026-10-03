#!/usr/bin/env python3
"""Build a minimal PFS0 ADF containing the cracktro executable.

Usage: python3 tools/make_adf.py [output.adf]
       defaults to build/neon_vectors.adf

Produces a 901120-byte (880 KiB) ADF with a valid PFS0 filesystem:
  - bootblock, volume, root, alloc blocks
  - S: directory with Startup-Sequence
  - ROOT: directory with NEON_VECTORS (the executable)
  - Startup-Sequence: `run ROOT:NEON_VECTORS & wait & quit`

Bootable by any Amiga emulator supporting PFS0 (FS-UAE, WinUAE, AmigaOS 1.3+).
The program exits when the left mouse button is pressed.
"""

import struct
import sys
import os

BLOCK = 512
TOTAL = 1760
ADF_SIZE = TOTAL * BLOCK  # 901120

BT_ROOT = 0x1E
BT_VOL = 0x1F
BT_ALLOC = 0x20
BT_DIR = 0x41
BT_FILE = 0x42
BF_DIR = 0x0004
BF_EXEC = 0x0010


class ADF:
    def __init__(self):
        self.data = bytearray(ADF_SIZE)

    def set_block(self, num, data):
        assert len(data) == BLOCK, 'block {} is {} bytes, need {}'.format(num, len(data), BLOCK)
        self.data[num * BLOCK:(num + 1) * BLOCK] = data

    def save(self, path):
        with open(path, 'wb') as f:
            f.write(self.data)
        with open(path, 'rb') as f:
            d = f.read()
        assert len(d) == ADF_SIZE, 'saved size {} != {}'.format(len(d), ADF_SIZE)


def w_i32(buf, off, val):
    struct.pack_into('>i', buf, off, val)


def w_i16(buf, off, val):
    struct.pack_into('>H', buf, off, val)


def w_str(buf, off, s, length):
    """Write a fixed-length zero-padded string at offset."""
    raw = s.encode('ascii')[:length]
    struct.pack_into('{}s'.format(length), buf, off, raw)


def tag(buf, off, nxt, prv, typ):
    w_i32(buf, off + 0, nxt)
    w_i32(buf, off + 4, prv)
    w_i16(buf, off + 8, typ)


def make_boot(root_blk):
    b = bytearray(BLOCK)
    w_i16(b, 0, 0x55AA)
    w_i16(b, 2, 0)
    w_i32(b, 4, root_blk)
    w_i32(b, 12, TOTAL)
    b[508] = 0x4e
    b[509] = 0x75
    b[510] = 0x00
    b[511] = 0x00
    return b


def make_volume(root_blk, alloc_blk, first_free, free_count):
    b = bytearray(BLOCK)
    tag(b, 0, alloc_blk, root_blk, BT_VOL)
    w_str(b, 16, 'NEON VECTORS', 24)
    w_i32(b, 40, root_blk)
    w_i32(b, 44, alloc_blk)
    w_i32(b, 48, TOTAL)
    w_i32(b, 52, first_free)
    w_i32(b, 56, free_count)
    return b


def make_alloc(vol_blk, first_free, free_count):
    b = bytearray(BLOCK)
    tag(b, 0, -1, vol_blk, BT_ALLOC)
    w_i32(b, 16, first_free)
    w_i32(b, 20, free_count)
    return b


def dir_entry(buf, off, nxt, prv, typ, flags, data_blk, size, name, exec_type=0):
    w_i32(buf, off + 0, nxt)
    w_i32(buf, off + 4, prv)
    w_i16(buf, off + 8, typ)
    w_i16(buf, off + 10, flags)
    w_i32(buf, off + 12, data_blk)
    w_i32(buf, off + 16, size)
    w_i32(buf, off + 20, 0)
    w_i16(buf, off + 24, 0)
    w_i16(buf, off + 26, 0)
    w_i16(buf, off + 28, exec_type)
    w_str(buf, off + 32, name, 32)


def make_dir(dirname, nxt, prv, entries):
    b = bytearray(BLOCK)
    tag(b, 0, nxt, prv, BT_DIR)
    w_str(b, 16, dirname, 24)
    for i, e in enumerate(entries):
        off = 40 + i * 48
        if off + 64 > BLOCK:
            break
        name, enxt, eprv, etyp, eflags, edata, esize, eexec = e
        dir_entry(b, off, enxt, eprv, etyp, eflags, edata, esize, name, eexec)
    return b


def make_file_header(fname, nxt, prv, data_blk, size, exec_type=0):
    b = bytearray(BLOCK)
    tag(b, 0, nxt, prv, BT_FILE)
    w_str(b, 16, fname, 24)
    dir_entry(b, 40, data_blk, -1, BT_FILE, 0, data_blk, size, fname, exec_type)
    return b


def build(prog_path, out_path):
    with open(prog_path, 'rb') as f:
        prog = f.read()

    a = ADF()

    startup = b'run ROOT:NEON_VECTORS\nwait\nquit\n'
    n_prog = (len(prog) + BLOCK - 1) // BLOCK
    n_startup = (len(startup) + BLOCK - 1) // BLOCK

    # Block layout:
    #  0: boot
    #  1: root
    #  2: volume
    #  3: alloc
    #  4: S: dir
    #  5: Startup-Sequence file header
    #  6: Startup-Sequence data
    #  7: ROOT: dir
    #  8: NEON_VECTORS file header
    #  9..8+n_prog: program data
    first_free = 9 + n_prog

    # 0: bootblock
    a.set_block(0, make_boot(1))

    # 2: volume
    a.set_block(2, make_volume(1, 3, first_free, TOTAL - first_free))

    # 3: alloc
    a.set_block(3, make_alloc(2, first_free, TOTAL - first_free))

    # 4: S: dir
    s_dir = make_dir('S', -1, 1, [
        ('Startup-Sequence', -1, -1, BT_FILE, 0, 6, len(startup), 0),
    ])
    a.set_block(4, s_dir)

    # 5: Startup-Sequence file header
    a.set_block(5, make_file_header('Startup-Sequence', -1, 4, 6, len(startup), 0))

    # 6: Startup-Sequence data
    sd = bytearray(BLOCK)
    for i, c in enumerate(startup):
        sd[i] = c
    a.set_block(6, sd)

    # 7: ROOT: dir
    root_dir = make_dir('ROOT', 4, 1, [
        ('NEON_VECTORS', -1, -1, BT_FILE, BF_EXEC, 9, len(prog), 0x0004),
    ])
    a.set_block(7, root_dir)

    # 8: NEON_VECTORS file header
    a.set_block(8, make_file_header('NEON_VECTORS', -1, 7, 9, len(prog), 0x0004))

    # 9..: program data
    for i in range(n_prog):
        chunk = prog[i * BLOCK:(i + 1) * BLOCK]
        blk = bytearray(BLOCK)
        for j, c in enumerate(chunk):
            blk[j] = c
        a.set_block(9 + i, blk)

    # 1: root block
    root = bytearray(BLOCK)
    tag(root, 0, 2, -1, BT_ROOT)
    dir_entry(root, 16, 7, -1, BT_DIR, BF_DIR, 4, 0, 'S')
    dir_entry(root, 64, -1, 4, BT_DIR, BF_DIR, 7, 0, 'ROOT')
    a.set_block(1, root)

    a.save(out_path)

    # Verify
    with open(out_path, 'rb') as f:
        d = f.read()
    assert len(d) == ADF_SIZE
    assert struct.unpack_from('>H', d, 0)[0] == 0x55AA
    assert struct.unpack_from('>H', d, 512 + 8)[0] == BT_ROOT
    assert struct.unpack_from('>H', d, 1024 + 8)[0] == BT_VOL
    assert struct.unpack_from('>H', d, 2048 + 8)[0] == BT_DIR
    assert struct.unpack_from('>H', d, 3584 + 8)[0] == BT_DIR
    # Verify program data
    for i in range(0, len(prog), 7):
        assert prog[i] == d[4608 + i], 'program byte {} mismatch'.format(i)

    print('ADF OK: {}'.format(out_path))
    print('  size: {} bytes'.format(ADF_SIZE))
    print('  program: {} bytes, {} blocks'.format(len(prog), n_prog))
    print('  first free: block {}'.format(first_free))
    print()
    print('Usage: load in FS-UAE/WinUAE as Floppy 0')
    print('Startup-Sequence auto-runs the cracktro. LEFT MOUSE to exit.')


if __name__ == '__main__':
    base = os.path.dirname(os.path.abspath(__file__))
    prog = os.path.join(base, '..', 'build', 'neon_vectors')
    out = os.path.join(base, '..', 'build', 'neon_vectors.adf')
    if len(sys.argv) > 1:
        out = sys.argv[1]
    build(prog, out)
