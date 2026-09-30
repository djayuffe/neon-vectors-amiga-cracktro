#!/usr/bin/env python3
"""Run the real assembled intro on an emulated 68000 and check what it does.

This is a behavioural test, not a cycle-exact Amiga emulator. It executes the
actual Hunk executable on the Musashi 68000 core (pip install machine68k) and
models just enough of the machine to judge the program:

  * Exec and graphics.library are stubs that take their arguments in the
    registers the real libraries use (a1 = name, a0 = source, ...), so a call
    with the wrong register convention fails here. Scratch registers
    (d1/a0/a1) are trashed on return, like the real ones may.
  * The custom chips are RAM-backed. DMACON/INTENA/INTREQ/ADKCON are decoded with
    SET/CLR semantics, VPOSR/VHPOSR follow a PAL beam derived from executed CPU
    cycles, and the Copper list in chip RAM is interpreted to render a frame.
  * Paula channel starts are latched when the DMA bit turns on and compared with
    what the MOD file says should play.

It does NOT prove the program works on real hardware: no blitter, no DMA cycle
stealing (so CPU timing is optimistic), no sprites, no Kickstart behaviour.
Use an emulator such as FS-UAE/WinUAE/Amiberry for that.

Usage: emu_test.py [--frames N] [--png FILE] [--alloc-fast] [--loader-chip]
"""
import argparse, os, shutil, struct, subprocess, sys, tempfile, zlib
from pathlib import Path

try:
    import machine68k as m68k
except ImportError:
    print('emu_test needs the Musashi binding:  pip install machine68k', file=sys.stderr)
    sys.exit(77)

ROOT = Path(__file__).resolve().parents[1]
LINE_CYCLES = 454                 # 227 colour clocks * 2 CPU cycles at 7.09 MHz
FRAME_LINES = 312
FRAME_CYCLES = LINE_CYCLES * FRAME_LINES
CUSTOM = 0xDFF000
CIAAPRA = 0xBFE001
EXEC, GFX = 0x1000, 0x3000
SENTINEL = 0x0800
STACK = 0x10000
CHIP_POOL, CHIP_END = 0x100000, 0x200000
FAST_POOL = 0x400000
FAST_SIZE_LIMIT = 0xE00000
R = m68k.Register
failures = []


def check(cond, msg):
    if not cond:
        failures.append(msg)
        print('  FAIL:', msg)
    return cond


# --- assemble a copy with symbols ---------------------------------------------
def find_vasm():
    for c in (os.environ.get('VASM'), shutil.which('vasmm68k_mot'), str(ROOT / 'tools/bin/vasmm68k_mot')):
        if c and Path(c).exists():
            return c
    sys.exit('emu_test: no vasmm68k_mot (run "make toolchain" or set VASM)')


def assemble(out):
    r = subprocess.run([find_vasm(), '-m68000', '-kick1hunks', '-Fhunkexe', '-I', str(ROOT / 'src'),
                        '-o', str(out), str(ROOT / 'src/main.s')], capture_output=True, text=True, cwd=ROOT)
    if r.returncode:
        sys.exit('emu_test: assembly failed\n' + r.stdout + r.stderr)


# --- Hunk loader ---------------------------------------------------------------
def parse_hunks(b):
    off = 0
    def u32():
        nonlocal off
        v = struct.unpack_from('>I', b, off)[0]; off += 4; return v
    assert u32() == 0x3F3
    while u32():
        pass
    n, first, last = u32(), u32(), u32()
    sizes, mem = [], []
    for _ in range(n):
        v = u32(); sizes.append((v & 0x3FFFFFFF) * 4); mem.append(v >> 30)
    hunks = []; cur = None; syms = {}
    while off < len(b):
        t = u32() & 0x3FFFFFFF
        if t == 0x3E8:                       # HUNK_NAME
            cnt = -struct.unpack_from('>i', b, off)[0]; off += 4 + (cnt - 1) * 4
        elif t in (0x3E9, 0x3EA):
            k = u32(); cur = dict(data=b[off:off + k * 4], relocs=[]); off += k * 4; hunks.append(cur)
        elif t == 0x3EB:
            k = u32(); hunks.append(dict(data=bytes(k * 4), relocs=[])); cur = hunks[-1]
        elif t == 0x3EC:
            while True:
                k = u32()
                if not k:
                    break
                tgt = u32(); cur['relocs'] += [(tgt, u32()) for _ in range(k)]
        elif t == 0x3F0:
            while True:
                k = u32() & 0xFFFFFF
                if not k:
                    break
                name = b[off:off + k * 4].split(b'\0')[0].decode('latin-1'); off += k * 4
                syms[name] = (len(hunks) - 1, u32())
        elif t == 0x3F2:
            pass
        else:
            raise ValueError('hunk type %x' % t)
    return sizes, mem, hunks, syms


class Amiga:
    def __init__(self, exe, loader_chip, alloc_fast):
        self.mach = m68k.Machine(m68k.CPUType.M68000, 15 * 1024)
        self.cpu, self.mem = self.mach.cpu, self.mach.mem
        self.alloc_fast = alloc_fast
        self.t = 0
        self.nest_forbid = self.nest_disable = 0
        self.chip_ptr, self.fast_ptr = CHIP_POOL, FAST_POOL
        self.allocs = {}
        self.calls = []
        self.loadviews = []
        self.opened = []
        self.gfx_open = 0
        # initial "system" state, deliberately non-trivial so a restore is visible
        self.dmacon = 0x03EF
        self.intena = 0xE02C
        self.adkcon = 0x1100
        self.intreq = 0
        self.cop1lc = 0
        self.init = (self.dmacon, self.intena, self.adkcon)
        self.latches = []            # (t, ch, ptr, len, per, vol)
        self.audio_on = [False] * 4
        self.raw = b'\0' * 10
        self.frame_marks = []        # WaitFrameSync entry times
        self.exit_marks = []
        self.pending_loopcheck = []
        self.loopregs = []           # (t, ch, ptr, len) sampled after a row
        self.chip_block = None
        self.mouse_down_at = None
        self.load(exe, loader_chip)

    # memory helpers
    def chip_alloc(self, size):
        a = (self.chip_ptr + 7) & ~7
        self.chip_ptr = a + size + 64
        assert self.chip_ptr < CHIP_END
        return a

    def fast_alloc(self, size):
        a = (self.fast_ptr + 7) & ~7
        self.fast_ptr = a + size + 64
        assert self.fast_ptr < FAST_SIZE_LIMIT
        return a

    def load(self, exe, loader_chip):
        self.sizes, memf, self.hunks, self.syms = parse_hunks(exe.read_bytes())
        self.bases = []
        for sz, mf in zip(self.sizes, memf):
            self.bases.append(self.chip_alloc(sz) if (mf == 1 and loader_chip) else self.fast_alloc(sz))
        self.hunk_mem = memf
        for i, h in enumerate(self.hunks):
            self.mem.w_block(self.bases[i], h['data'])
        for i, h in enumerate(self.hunks):
            for tgt, o in h['relocs']:
                a = self.bases[i] + o
                self.mem.w32(a, (self.mem.r32(a) + self.bases[tgt]) & 0xFFFFFFFF)
        self.orig = [self.mem.r_block(self.bases[i], self.sizes[i]) for i in range(len(self.hunks))]

    def sym(self, name):
        h, o = self.syms[name]
        return self.bases[h] + o

    # library stubs
    def install(self):
        mem = self.mem
        mem.w32(4, EXEC)
        mem.w32(GFX + 34, 0x5555)       # ActiView
        mem.w32(GFX + 38, 0x6666)       # copinit
        self.view, self.copinit = 0x5555, 0x6666
        exec_fns = {-120: self.f_disable, -126: self.f_enable, -132: self.f_forbid, -138: self.f_permit,
                    -198: self.f_allocmem, -210: self.f_freemem, -408: self.f_openlib, -414: self.f_closelib,
                    -534: self.f_typeofmem, -624: self.f_copymem}
        gfx_fns = {-222: self.f_loadview, -228: self.f_waitblit, -270: self.f_waittof,
                   -456: self.f_ownblit, -462: self.f_disownblit}
        self.stubs = {EXEC + k: v for k, v in exec_fns.items()}
        self.stubs.update({GFX + k: v for k, v in gfx_fns.items()})
        self.stub_ranges = [(EXEC - 700, EXEC), (GFX - 500, GFX)]
        # custom register defaults
        mem.w16(CUSTOM + 0x02, self.dmacon); mem.w16(CUSTOM + 0x1C, self.intena)
        mem.w16(CUSTOM + 0x10, self.adkcon)
        mem.w8(CIAAPRA, 0xFF)

    def ret(self):
        sp = self.cpu.r_reg(R.A7)
        self.cpu.w_pc(self.mem.r32(sp)); self.cpu.w_reg(R.A7, sp + 4)

    def scratch(self, d0=None):
        c = self.cpu
        if d0 is not None:
            c.w_reg(R.D0, d0 & 0xFFFFFFFF)
        c.w_reg(R.D1, 0xDEAD0001); c.w_reg(R.A0, 0xDEAD0002); c.w_reg(R.A1, 0xDEAD0003)

    def reg(self, r):
        return self.cpu.r_reg(r)

    def f_forbid(self):
        self.nest_forbid += 1; self.calls.append('Forbid'); self.scratch(); self.ret()

    def f_permit(self):
        check(self.nest_forbid > 0, 'Permit without Forbid'); self.nest_forbid -= 1
        self.calls.append('Permit'); self.scratch(); self.ret()

    def f_disable(self):
        check(self.nest_forbid > 0, 'Disable called outside Forbid')
        self.nest_disable += 1; self.intena &= ~0x4000; self.sync_read_regs()
        self.calls.append('Disable'); self.scratch(); self.ret()

    def f_enable(self):
        check(self.nest_disable > 0, 'Enable without Disable'); self.nest_disable -= 1
        if not self.nest_disable:
            self.intena |= 0xC000
        self.sync_read_regs(); self.calls.append('Enable'); self.scratch(); self.ret()

    def f_allocmem(self):
        size, flags = self.reg(R.D0), self.reg(R.D1)
        check(not self.nest_disable, 'AllocMem called with interrupts disabled')
        self.calls.append('AllocMem')
        if self.alloc_fast or not (flags & 2):
            a = self.fast_alloc(size)
        else:
            a = self.chip_alloc(size)
        self.mem.w_block(a - 16, b'\xA5' * 16); self.mem.w_block(a + size, b'\xA5' * 16)
        self.mem.w_block(a, b'\x55' * size)          # no MEMF_CLEAR: memory arrives dirty
        self.allocs[a] = (size, flags)
        self.scratch(a); self.ret()

    def f_freemem(self):
        a, size = self.reg(R.A1), self.reg(R.D0)
        self.calls.append('FreeMem')
        check(a in self.allocs, 'FreeMem of a block that was not allocated (a1=$%X)' % a)
        if a in self.allocs:
            check(self.allocs[a][0] == size, 'FreeMem size %d != allocated %d' % (size, self.allocs[a][0]))
            for base, off in ((a - 16, 0), (a + size, 0)):
                check(self.mem.r_block(base, 16) == b'\xA5' * 16, 'memory guard around the allocation was overwritten')
            del self.allocs[a]
        self.scratch(); self.ret()

    def f_typeofmem(self):
        a = self.reg(R.A1)
        self.calls.append('TypeOfMem')
        self.scratch(0x2 if a < CHIP_END else 0x4); self.ret()

    def f_copymem(self):
        src, dst, n = self.reg(R.A0), self.reg(R.A1), self.reg(R.D0)
        self.calls.append('CopyMem')
        check(src in self.bases, 'CopyMem source $%X is not a hunk base (source/dest swapped?)' % src)
        check(dst in self.allocs, 'CopyMem destination $%X is not an allocated block' % dst)
        if src in self.bases and dst in self.allocs:
            check(n <= self.allocs[dst][0], 'CopyMem length exceeds the allocation')
            self.mem.w_block(dst, self.mem.r_block(src, n))
        self.scratch(); self.ret()

    def f_openlib(self):
        name = self.mem.r_cstr(self.reg(R.A1)) if self.reg(R.A1) < 0xE00000 else ''
        self.calls.append('OldOpenLibrary')
        ok = check(name == 'graphics.library', 'OldOpenLibrary name pointer (a1) does not point at "graphics.library": %r' % name)
        self.gfx_open += 1 if ok else 0
        self.scratch(GFX if ok else 0); self.ret()

    def f_closelib(self):
        self.calls.append('CloseLibrary')
        check(self.reg(R.A1) == GFX, 'CloseLibrary base (a1) is not the opened library')
        self.gfx_open -= 1; self.scratch(); self.ret()

    def f_loadview(self):
        v = self.reg(R.A1)
        self.calls.append('LoadView'); self.loadviews.append(v)
        self.scratch(); self.ret()

    def f_waitblit(self):
        self.calls.append('WaitBlit'); self.scratch(); self.ret()

    def f_ownblit(self):
        self.calls.append('OwnBlitter'); self.scratch(); self.ret()

    def f_disownblit(self):
        self.calls.append('DisownBlitter'); self.scratch(); self.ret()

    def f_waittof(self):
        check(not self.nest_disable, 'WaitTOF with interrupts disabled would hang on real hardware')
        self.calls.append('WaitTOF')
        self.t = (self.t // FRAME_CYCLES + 1) * FRAME_CYCLES
        self.scratch(); self.ret()

    # chipset model
    def sync_read_regs(self):
        w = self.mem.w16
        w(CUSTOM + 0x02, self.dmacon); w(CUSTOM + 0x1C, self.intena)
        w(CUSTOM + 0x1E, self.intreq); w(CUSTOM + 0x10, self.adkcon)

    def beam(self):
        line = (self.t // LINE_CYCLES) % FRAME_LINES
        hpos = min((self.t % LINE_CYCLES) // 2, 0xE3)
        self.mem.w32(CUSTOM + 4, ((line >> 8) << 16) | ((line & 0xFF) << 8) | hpos)

    @staticmethod
    def setclr(state, v):
        return (state | (v & 0x7FFF)) if v & 0x8000 else (state & ~v & 0x7FFF)

    def poll_custom(self):
        raw = self.mem.r_block(CUSTOM + 0x96, 10)
        if raw == self.raw:
            return
        old = self.raw; self.raw = raw
        dm, ie, ir, ak = (struct.unpack('>H', raw[i:i + 2])[0] for i in (0, 4, 6, 8))
        if raw[0:2] != old[0:2]:
            self.dmacon = self.setclr(self.dmacon, dm) & 0x07FF
            self.check_audio_edges()
        if raw[4:6] != old[4:6]:
            self.intena = self.setclr(self.intena, ie)
        if raw[6:8] != old[6:8]:
            self.intreq = self.setclr(self.intreq, ir)
        if raw[8:10] != old[8:10]:
            self.adkcon = self.setclr(self.adkcon, ak)
        self.sync_read_regs()

    def check_audio_edges(self):
        for ch in range(4):
            on = bool(self.dmacon & 0x200) and bool(self.dmacon & (1 << ch))
            if on and not self.audio_on[ch]:
                base = CUSTOM + 0xA0 + ch * 16
                self.latches.append((self.t, ch, self.mem.r32(base), self.mem.r16(base + 4),
                                     self.mem.r16(base + 6), self.mem.r16(base + 8)))
            self.audio_on[ch] = on

    def cop_events(self):
        """Interpret the Copper list once per frame: [(line, register, value)]."""
        ev, line, a = [], 0, self.cop1lc_addr()
        for _ in range(4096):
            w1, w2 = self.mem.r16(a), self.mem.r16(a + 2); a += 4
            if w1 & 1:
                if (w1, w2) == (0xFFFF, 0xFFFE):
                    return ev, True
                line = max(line, w1 >> 8)
            else:
                ev.append((line, w1, w2))
        return ev, False

    def cop1lc_addr(self):
        return self.mem.r32(CUSTOM + 0x80)

    # execution
    def run(self, frames, snap_frame):
        cpu, mem = self.cpu, self.mem
        self.install()
        mem.w32(0, STACK)
        cpu.pulse_reset()
        cpu.w_pc(self.bases[0]); cpu.w_reg(R.A7, STACK - 4)
        mem.w32(STACK - 4, SENTINEL)
        sentinel_regs = [0x11110000 + i for i in range(1, 8)] + [0x22220000 + i for i in range(7)]
        for i in range(1, 8):
            cpu.w_reg(R.D0 + i, sentinel_regs[i - 1])
        for i in range(7):
            cpu.w_reg(R.A0 + i, sentinel_regs[7 + i])
        self.sentinel_regs = sentinel_regs
        wfs = self.sym('WaitFrameSync')
        self.exit_pc = None
        self.exit_times = []
        self.snapshot = None
        steps = 0
        while True:
            pc = cpu.r_pc()
            fn = self.stubs.get(pc)
            if fn:
                fn(); continue
            if pc == SENTINEL:
                break
            for lo, hi in self.stub_ranges:
                if lo <= pc < hi:
                    failures.append('jump into an unimplemented library vector at $%X' % pc); return False
            if pc == self.exit_pc:
                self.exit_times.append(self.t); self.exit_pc = None
            if pc == wfs:
                self.exit_pc = mem.r32(cpu.r_reg(R.A7))
                self.frame_marks.append(self.t)
                self.sample_loop_regs()
                n = len(self.frame_marks)
                if n == snap_frame and FRAME_LINES == 312:
                    self.snapshot = self.render()
                if n == frames:
                    mem.w8(CIAAPRA, 0xFF & ~0x40)      # press the left mouse button
            n = cpu.execute(1).cycles
            self.t += n
            steps += 1
            self.beam()
            self.poll_custom()
            if self.t > (frames + 40) * FRAME_CYCLES:
                failures.append('program did not exit within 40 frames after the mouse press')
                return False
        return True

    def render(self):
        """Interpret the Copper list and bitplanes exactly as the chipset would show them."""
        mem = self.mem
        out = dict(dmacon=self.dmacon, intena=self.intena)
        out['shifts'] = (mem.r32(self.sym('scroll_ptr')) - self.sym('scroll_text')) * 8 + mem.r8(self.sym('glyph_col'))
        a = mem.r32(CUSTOM + 0x80)
        ev, line, terminated = [], 0, False
        for _ in range(4096):
            w1, w2 = mem.r16(a), mem.r16(a + 2); a += 4
            if w1 & 1:
                if (w1, w2) == (0xFFFF, 0xFFFE):
                    terminated = True; break
                line = max(line, w1 >> 8)
            else:
                ev.append((line, w1, w2))
        out['terminated'] = terminated
        first = {}
        for ln, r, v in ev:
            if ln == 0:
                first[r] = v
        out['first'] = first
        ptr = {}
        for i in range(3):
            ptr[i] = (first.get(0xE0 + 4 * i, 0) << 16) | first.get(0xE2 + 4 * i, 0)
        out['ptr'] = ptr
        pal = {i: 0 for i in range(8)}
        rows = []
        evs = sorted(ev, key=lambda e: e[0])
        pending = list(evs)
        pal_by_line = {}
        cur = dict(pal)
        for y in range(FRAME_LINES):
            while pending and pending[0][0] <= y:
                _, r, v = pending.pop(0)
                if 0x180 <= r < 0x1A0:
                    cur[(r - 0x180) // 2] = v
            pal_by_line[y] = dict(cur)
        diwstrt, diwstop = first.get(0x8E, 0), first.get(0x90, 0)
        y0 = diwstrt >> 8
        y1 = (diwstop >> 8) | 0x100
        out['diw'] = (y0, y1)
        img = []
        planes_px = []
        for y in range(y0, y1):
            rowpix = []
            for x in range(320):
                v = 0
                for p in range(3):
                    byte = mem.r8(ptr[p] + (y - y0) * 40 + (x >> 3))
                    v |= ((byte >> (7 - (x & 7))) & 1) << p
                rowpix.append(v)
            planes_px.append(rowpix)
            pal_l = pal_by_line[y]
            img.append([pal_l[v] for v in rowpix])
        out['px'] = planes_px
        out['img'] = img
        out['pal128'] = pal_by_line[0x80][0]
        return out

    def sample_loop_regs(self):
        for ch in self.pending_loopcheck:
            base = CUSTOM + 0xA0 + ch * 16
            self.loopregs.append((self.t, ch, self.mem.r32(base), self.mem.r16(base + 4)))
        prev = self.frame_marks[-2] if len(self.frame_marks) > 1 else 0
        self.pending_loopcheck = sorted({l[1] for l in self.latches if l[0] > prev})


# --- checks ---------------------------------------------------------------------
def png(path, w, h, rows):
    raw = b''.join(b'\0' + bytes(r) for r in rows)
    def chunk(t, d):
        return struct.pack('>I', len(d)) + t + d + struct.pack('>I', zlib.crc32(t + d) & 0xFFFFFFFF)
    path.write_bytes(b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', w, h, 8, 2, 0, 0, 0)) +
                     chunk(b'IDAT', zlib.compress(raw, 9)) + chunk(b'IEND', b''))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--frames', type=int, default=800, help='frames to run before pressing the mouse button')
    ap.add_argument('--png', help='write the rendered frame as a PNG')
    ap.add_argument('--snap', type=int, default=700, help='frame to render and check')
    ap.add_argument('--alloc-fast', action='store_true', help='make AllocMem return fast RAM (failure path)')
    ap.add_argument('--ntsc', action='store_true', help='262 line frame: the PAL-only intro must still run and exit, not hang')
    ap.add_argument('--loader-chip', action='store_true', help='let the loader honour the chip hunk flag')
    args = ap.parse_args()
    global FRAME_LINES, FRAME_CYCLES
    if args.ntsc:
        FRAME_LINES = 262; FRAME_CYCLES = LINE_CYCLES * FRAME_LINES

    tmp = Path(tempfile.mkdtemp(prefix='neon_emu_'))
    exe = tmp / 'neon_vectors_sym'
    assemble(exe)
    mod = (ROOT / 'assets/neon.mod').read_bytes()
    logo = (ROOT / 'assets/logo.raw').read_bytes()
    font = (ROOT / 'assets/font.raw').read_bytes()

    a = Amiga(exe, args.loader_chip, args.alloc_fast)
    snap_frame = min(args.snap, args.frames - 1)
    print('running %d frames ...' % args.frames)
    ok = a.run(args.frames, snap_frame)
    mem = a.mem

    # ---------------------------------------------------------------- exit state
    print('exit path')
    if args.alloc_fast:
        check(a.cpu.r_reg(R.D0) == 20, 'alloc failure must return RETURN_FAIL (20), got %d' % a.cpu.r_reg(R.D0))
        check(not a.allocs, 'memory leaked after failed chip allocation')
        check(a.gfx_open == 0, 'graphics.library left open')
        check('LoadView' not in a.calls, 'display was taken over although allocation failed')
        finish()
        return
    if not ok:
        finish(); return
    c = a.cpu
    check(c.r_reg(R.D0) == 0, 'return code d0 = %d, expected 0' % c.r_reg(R.D0))
    for i in range(1, 8):
        check(c.r_reg(R.D0 + i) == a.sentinel_regs[i - 1], 'd%d not preserved' % i)
    for i in range(7):
        check(c.r_reg(R.A0 + i) == a.sentinel_regs[7 + i], 'a%d not preserved' % i)
    check(c.r_reg(R.A7) == STACK, 'stack pointer not restored (sp=$%X)' % c.r_reg(R.A7))
    check(a.nest_forbid == 0 and a.nest_disable == 0, 'Forbid/Disable nesting not balanced')
    check(not a.allocs, 'chip memory leaked: %s' % {hex(k): v for k, v in a.allocs.items()})
    check(a.gfx_open == 0, 'graphics.library not closed')
    check(a.loadviews == [0, a.view], 'LoadView calls %s, expected [NULL, old view]' % a.loadviews)
    check(mem.r32(CUSTOM + 0x80) == a.copinit, 'COP1LC is not the system copinit list ($%X)' % mem.r32(CUSTOM + 0x80))
    i_dm, i_ie, i_ak = a.init
    check(a.dmacon == (i_dm & 0x07F0), 'DMACON $%04X != restored $%04X (audio must stay off)' % (a.dmacon, i_dm & 0x07F0))
    check(a.intena & 0x3FFF == i_ie & 0x3FFF and a.intena & 0x8000, 'INTENA $%04X not restored from $%04X' % (a.intena, i_ie))
    check(a.adkcon == i_ak, 'ADKCON $%04X not restored from $%04X' % (a.adkcon, i_ak))
    order = [x for x in a.calls if x in ('Forbid', 'Disable', 'Enable', 'Permit')]
    check(order == ['Forbid', 'Disable', 'Enable', 'Permit'], 'scheduler call order %s' % order)
    for i, h in enumerate(a.hunks):
        now = mem.r_block(a.bases[i], a.sizes[i])
        if i == 0:
            check(now == a.orig[i], 'code hunk was modified while running')
        if a.hunk_mem[i] == 1 and not args.loader_chip:
            check(now == a.orig[i], 'the link-time chip hunk was modified: code used a link-time address instead of the chip copy')

    if args.ntsc:
        print('  NTSC frame: intro ran and exited without hanging (timing is not meaningful here)')
        finish(); return

    # ---------------------------------------------------------------- frame pacing
    print('frame pacing')
    fm = a.frame_marks
    deltas = {(y // FRAME_CYCLES) - (x // FRAME_CYCLES) for x, y in zip(fm, fm[1:])}
    check(deltas == {1}, 'the main loop must advance exactly one frame per iteration, saw frame deltas %s' % sorted(deltas))
    work = [t1 - t0 for t0, t1 in zip(a.exit_times, fm[1:])]
    worst = max(work)
    window = (FRAME_LINES - 300 + 44) * LINE_CYCLES
    print('  per-frame CPU work: avg %d, worst %d cycles (%.0f%% of a frame; vblank window %d cycles, no DMA contention modelled)'
          % (sum(work) // len(work), worst, 100.0 * worst / FRAME_CYCLES, window))
    if worst > window:
        print('  NOTE: the worst frame overruns the vblank window, so drawing can still be in progress when the display starts (tearing)')

    # ---------------------------------------------------------------- audio
    print('audio')
    sl = mod[950]
    pats = max(mod[952:952 + sl]) + 1
    smp = []
    off = 1084 + pats * 1024
    for i in range(31):
        o = 20 + i * 30
        ln = int.from_bytes(mod[o + 22:o + 24], 'big'); ls = int.from_bytes(mod[o + 26:o + 28], 'big')
        ll = int.from_bytes(mod[o + 28:o + 30], 'big'); vol = mod[o + 25]
        smp.append((off, ln, ls, ll, vol)); off += ln * 2
    ptr_mod = mem.r32(a.sym('reloc_table') + 16)
    chip_mod_lo, chip_mod_hi = ptr_mod, ptr_mod + len(mod)
    silence = mem.r32(a.sym('reloc_table') + 12)
    expected = []
    order_tab = mod[952:952 + sl]
    n_rows = (len(fm) - 1) // 6 + 1          # the loop body runs len(fm) times; rows start on iterations 1, 7, 13, ...
    for r in range(n_rows):
        base = 1084 + order_tab[(r // 64) % sl] * 1024 + (r % 64) * 16
        for ch in range(4):
            b0, b1, b2, b3 = mod[base + ch * 4: base + ch * 4 + 4]
            sn = (b0 & 0xF0) | (b2 >> 4); per = ((b0 & 15) << 8) | b1
            if sn and per:
                o, ln, ls, ll, vol = smp[sn - 1]
                expected.append((r, ch, o, max(ln, 1), per, vol, ls, ll))
    got = [(l[1], l[2] - chip_mod_lo, l[3], l[4], l[5]) for l in a.latches]
    exp = [(e[1], e[2], e[3], e[4], e[5]) for e in expected]
    check(len(got) == len(exp), 'audio triggers: got %d, expected %d' % (len(got), len(exp)))
    bad = [(i, g, e) for i, (g, e) in enumerate(zip(got, exp)) if g != e]
    check(not bad, 'audio trigger mismatch (idx, got (ch,offset,words,period,vol), expected): %s' % bad[:3])
    for lt in a.latches:
        check(chip_mod_lo <= lt[2] and lt[2] + lt[3] * 2 <= chip_mod_hi, 'Paula would fetch outside the module: $%X len %d' % (lt[2], lt[3]))
    rows_t = sorted({l[0] // FRAME_CYCLES for l in a.latches})
    if len(rows_t) > 2:
        gaps = {y - x for x, y in zip(rows_t, rows_t[1:])}
        check(gaps <= {6, 12, 18, 24}, 'tracker rows not a multiple of 6 frames apart: gaps %s' % sorted(gaps))
    want = {}
    for e in expected:
        o, ln, ls, ll = e[2], e[3], e[6], e[7]
        want.setdefault(e[1], []).append((o + ls * 2 + chip_mod_lo, ll) if ll > 1 else (silence, 1))
    seen = {}
    for (t, ch, p, ln) in a.loopregs:
        seen.setdefault(ch, []).append((p, ln))
    for ch in range(4):
        if ch in want and ch in seen:
            n = min(len(want[ch]), len(seen[ch]))
            check(seen[ch][:n] == want[ch][:n], 'channel %d loop/terminal registers wrong: got %s want %s'
                  % (ch, [(hex(x), y) for x, y in seen[ch][:2]], [(hex(x), y) for x, y in want[ch][:2]]))
    print('  %d channel starts over %d rows match the module' % (len(got), n_rows))
    check(mem.r16(silence) == 0x8080 if a.hunk_mem[2] != 1 or args.loader_chip else True, 'silence word is not $8080')

    # ---------------------------------------------------------------- display
    print('display (frame %d)' % snap_frame)
    sn = a.snapshot
    if not check(sn is not None, 'no frame snapshot was taken'):
        finish(); return
    check(sn['terminated'], 'Copper list does not end with $FFFF,$FFFE')
    check(sn['dmacon'] & 0x3A0 == 0x380 + 0 or (sn['dmacon'] & 0x380) == 0x380, 'master, bitplane and Copper DMA are not all enabled (DMACON=$%04X)' % sn['dmacon'])
    check(all(l[3] >= 1 and l[2] != 0 for l in a.latches), 'a channel was started with no sample loaded (Paula would play noise): %s' % [l for l in a.latches if l[3] < 1 or l[2] == 0][:2])
    check(sn['diw'] == (0x2C, 0x12C), 'display window lines %s, expected (44, 300)' % (sn['diw'],))
    scr = mem.r32(a.sym('reloc_table') + 0)
    for i in range(3):
        check(sn['ptr'][i] == scr + i * 10240, 'bitplane %d pointer $%X != $%X' % (i, sn['ptr'][i], scr + i * 10240))
    px = sn['px']
    def plane_bit(y, x, p):
        return (px[y][x] >> p) & 1
    # logo: plane 0, lines 48..111 (screen line = display line - 44 + 44 = same index)
    logo_bad = 0
    for y in range(256):
        for x in range(320):
            want_bit = 0
            if 48 <= y < 112:
                want_bit = (logo[(y - 48) * 40 + (x >> 3)] >> (7 - (x & 7))) & 1
            if plane_bit(y, x, 0) != want_bit:
                logo_bad += 1
    check(logo_bad == 0, 'plane 0 differs from the logo in %d pixels' % logo_bad)
    # stars: plane 2 holds exactly the 32 stars at their computed positions
    frames_done = snap_frame                       # UpdateStars has run snap_frame - 1 times before the snapshot
    nstars_calls = snap_frame - 1
    want_px = set()
    x0 = 0
    for i in range(32):
        y = 128 + ((x0 * 37) & 63)
        want_px.add(((x0 + nstars_calls) % 320, y))
        x0 = (x0 + 73) % 320
    got_px = {(x, y) for y in range(256) for x in range(320) if plane_bit(y, x, 2)}
    check(got_px == want_px, 'stars: %d missing, %d unexpected (trails/garbage) of %d' % (len(want_px - got_px), len(got_px - want_px), len(want_px)))
    # scroller: plane 1, lines 210..225, exact columns from the font
    tb = bytes(mem.r_block(a.sym('scroll_text'), 400)).split(b'\0')[0]
    shifts = sn['shifts']
    check(shifts == (snap_frame - 1) // 2, 'scroller advanced %d pixels in %d frames, expected %d' % (shifts, snap_frame - 1, (snap_frame - 1) // 2))
    L = len(tb)
    def stream_bit(k, row):
        if k < 0:
            return 0
        ch = tb[(k // 8) % L]
        g = ch - 32 if 32 <= ch < 127 else 0
        return (font[g * 8 + row // 2] >> (7 - (k % 8))) & 1
    sc_bad = 0
    for y in range(16):
        for x in range(320):
            want_bit = stream_bit(shifts - (319 - x), y)
            if plane_bit(210 + y, x, 1) != want_bit:
                sc_bad += 1
    check(sc_bad == 0, 'scroller band differs from the expected text in %d pixels (shift count %d)' % (sc_bad, shifts))
    outside = sum(plane_bit(y, x, 1) for y in range(256) for x in range(320) if not 210 <= y < 226)
    check(outside == 0, 'scroller plane has %d stray pixels outside its band' % outside)
    # raster colour at line 128 comes from the animated slot
    pal = [0x102,0x203,0x304,0x405,0x506,0x607,0x708,0x819,0x92A,0xA3B,0xB4C,0xC5D,0xD6E,0xE7F,0xD6E,0xC5D,
           0xB4C,0xA3B,0x92A,0x819,0x708,0x607,0x506,0x405,0x304,0x203,0x102,0x213,0x324,0x435,0x546,0x657]
    check(sn['pal128'] in pal, 'raster slot colour $%03X is not from the colour table' % sn['pal128'])
    print('  logo, %d stars and the scroller match their expected pixels' % len(want_px))
    if args.png:
        pal_rgb = lambda v: bytes(((v >> 8) & 15) * 17 for _ in range(1)) + bytes(((v >> 4) & 15) * 17 for _ in range(1)) + bytes((v & 15) * 17 for _ in range(1))
        rows = []
        for row in sn['img']:
            r = b''.join(pal_rgb(v) * 2 for v in row)
            rows += [r, r]
        png(Path(args.png), 640, len(rows), rows)
        print('  wrote', args.png)
    finish()


def finish():
    if failures:
        print('\nEMULATION TEST FAILED (%d)' % len(failures))
        sys.exit(1)
    print('\nEMULATION TEST PASSED')


if __name__ == '__main__':
    main()
