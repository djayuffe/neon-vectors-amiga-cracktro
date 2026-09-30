#!/usr/bin/env python3
"""Mutation self-test of tools/emu_test.py: inject faults into the graphics, audio and
startup code and require the emulated-68000 test to fail each time.

Slow (every mutant is a full emulated run), so it is separate from `make mutants`.
Requires machine68k (pip install machine68k).
"""
import shutil, subprocess, sys, tempfile
from pathlib import Path

R = Path(__file__).resolve().parents[1]
M = Path(tempfile.gettempdir()) / 'neon_vectors_emumut'

MUTANTS = [
    ('octant table: two entries swapped', 'src/main.s',
     '        dc.b $11,$15,$19,$1D ', '        dc.b $11,$15,$1D,$19 ', 'wireframe'),
    ('ONEDOT set (gappy shallow lines)', 'src/main.s',
     '        dc.b $11,$15,$19,$1D ', '        dc.b $13,$15,$19,$1D ', 'wireframe'),
    ('wireframe not double buffered', 'src/main.s',
     '        eori.w  #1,wire_front\n        bsr     PatchCopper', '        bsr     PatchCopper', 'alternate'),
    ('band clear far too short', 'src/main.s',
     '(MID_H<<6)|(SCREEN_W_BYTES/2),BLTSIZE', '((MID_H-60)<<6)|(SCREEN_W_BYTES/2),BLTSIZE', 'wireframe'),
    ('rotation matrix m20 sign', 'src/main.s',
     '        move.w  sy,d0\n        neg.w   d0\n        move.w  d0,12(a2)', '        move.w  sy,d0\n        move.w  d0,12(a2)', 'wireframe'),
    ('star erase missing (trails)', 'src/main.s',
     '        and.b   d1,0(a0,d2.w)', '        nop', 'plane 0'),
    ('scroller shifts one longword too many', 'src/main.s',
     'moveq   #SCREEN_W_BYTES/4-1,d6', 'moveq   #SCREEN_W_BYTES/4,d6', 'plane 0'),
    ('blitter DMA never enabled', 'src/main.s',
     'DMAF_COPPER|DMAF_BLITTER),DMACON(a6)', 'DMAF_COPPER),DMACON(a6)', 'blitter DMA'),
    ('Copper wrap below line 255 missing', 'src/main.s',
     '        dc.w $FFDF,$FFFE                    ; wrap: lines below are 256 + WAIT line\n', '', 'Copper wrap'),
    ('AUDxLEN written as words minus one', 'src/modplayer.s',
     '        move.w  d5,4(a1)\n        move.w  d1,6(a1)', '        subq.w  #1,d5\n        move.w  d5,4(a1)\n        move.w  d1,6(a1)', 'audio'),
    ('CopyMem source/destination swapped', 'src/main.s',
     '        lea     chipdata_begin,a0\n        move.l  chip_base,a1', '        lea     chipdata_begin,a1\n        move.l  chip_base,a0', 'CopyMem'),
    ('no frame-sync edge detection', 'src/main.s',
     '.leave:\n        bsr     BeamLine\n        cmp.w   #FRAME_SYNC_LINE,d0\n        bhs     .leave', '.leave:', 'frame'),
    ('chip memory never freed', 'src/main.s',
     '        jsr     LVO_FreeMem(a6)\n\n        move.l  gfx_base,a1                ; CloseLibrary', '        move.l  gfx_base,a1                ; CloseLibrary', 'leaked'),
    ('teardown waits with the VERTB interrupt masked', 'src/main.s',
     '        move.w  old_intena,d0\n        andi.w  #$7FFF,d0\n        ori.w   #$8000,d0\n        move.w  d0,INTENA(a6)\n', '', 'hang'),
]

def run(name, rel, old, new, expect):
    if M.exists():
        shutil.rmtree(M)
    M.mkdir(parents=True)
    for d in ('src', 'tools', 'assets'):
        shutil.copytree(R / d, M / d, ignore=shutil.ignore_patterns('bin', '__pycache__'))
    bin_dir = R / 'tools/bin'
    if bin_dir.exists():
        shutil.copytree(bin_dir, M / 'tools/bin')
    f = M / rel
    s = f.read_text()
    if old not in s:
        print(f'{name:<50} SETUP ERROR: pattern not found'); return False
    f.write_text(s.replace(old, new, 1))
    p = subprocess.run([sys.executable, str(M / 'tools/emu_test.py'), '--frames', '300', '--snap', '250'],
                       capture_output=True, text=True)
    out = p.stdout + p.stderr
    if p.returncode == 0:
        print(f'{name:<50} NOT CAUGHT'); return False
    fails = [l.strip() for l in out.splitlines() if l.strip().startswith('FAIL')]
    if expect and not any(expect.lower() in l.lower() for l in fails) and 'Traceback' not in out:
        print(f'{name:<50} caught, but without "{expect}": {fails[:1]}'); return True
    print(f'{name:<50} caught: {(fails[0] if fails else out.splitlines()[-1])[:70]}')
    return True

if __name__ == '__main__':
    results = [run(*m) for m in MUTANTS]
    print(f'\nemulation mutants caught: {sum(results)}/{len(results)}')
    sys.exit(0 if all(results) else 1)
