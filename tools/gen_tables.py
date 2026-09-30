#!/usr/bin/env python3
"""Print the generated tables that are pasted into src/main.s.

    python3 tools/gen_tables.py copper   # Copper colour-gradient WAIT/MOVE lines
    python3 tools/gen_tables.py sintab   # 256-entry sine table, amplitude 127
    python3 tools/gen_tables.py recip_star | recip_wire   # reciprocal tables that replace divisions

The output is deterministic. It is kept as a script (rather than generated at build
time) so the assembler input stays a single readable file that the validator can parse.
"""
import math, sys

def lerp(c0, c1, t):
    out = 0
    for sh in (8, 4, 0):
        a, b = (c0 >> sh) & 15, (c1 >> sh) & 15
        out |= int(round(a + (b - a) * t)) << sh
    return out

def ramp(stops, t):
    """stops: [(pos, colour)], t in 0..1"""
    for (p0, c0), (p1, c1) in zip(stops, stops[1:]):
        if t <= p1:
            return lerp(c0, c1, 0 if p1 == p0 else (t - p0) / (p1 - p0))
    return stops[-1][1]

DISPLAY_TOP = 44            # first display line; screen y maps to line y + 44

def copper():
    ent = []                # (y, [(reg, value)])
    # Logo band, y 8..71: text colour (COLOR01) and background (COLOR00), every 2 lines.
    text = [(0.0, 0xFFF), (0.35, 0xFF9), (0.6, 0xFB4), (1.0, 0xE52)]
    bg = [(0.0, 0x002), (1.0, 0x214)]
    for i in range(32):
        t = i / 31
        ent.append((8 + 2 * i, [('COLOR00', ramp(bg, t)), ('COLOR01', ramp(text, t))]))
    ent.append((72, None))                                   # animated raster slot, 4 lines
    # Middle band, y 76..195: mid-distance star colour plus a faint depth gradient behind.
    ent.append((76, [('COLOR00', 0x001), ('COLOR01', 0xAAD)]))
    mid = [(0.0, 0x001), (0.5, 0x024), (1.0, 0x001)]
    for i in range(1, 15):
        ent.append((76 + 8 * i, [('COLOR00', ramp(mid, i / 14))]))
    # Scroller strip, y 197..218: frame lines, dark bar, gradient text colour.
    ent.append((196, [('COLOR00', 0x001)]))
    ent.append((197, [('COLOR00', 0x6CF)]))
    ent.append((198, [('COLOR00', 0x124)]))
    sc = [(0.0, 0x7EF), (0.5, 0xFFF), (1.0, 0x5BE)]
    for i in range(8):
        ent.append((200 + 2 * i, [('COLOR01', ramp(sc, i / 7))]))
    ent.append((218, [('COLOR00', 0x6CF)]))
    ent.append((219, [('COLOR00', 0x001)]))
    # Floor bars below the scroller, y 222..255, every 4 lines.
    fl = [(0.0, 0x102), (1.0, 0x63A)]
    for i in range(9):
        ent.append((222 + 4 * i, [('COLOR00', ramp(fl, i / 8) if i % 2 == 0 else 0x001)]))
    ent.sort(key=lambda e: e[0])
    lines, wrapped = [], False
    for y, regs in ent:
        v = DISPLAY_TOP + y
        if v > 255 and not wrapped:
            lines.append('        dc.w $FFDF,$FFFE                    ; wrap: lines below are 256 + WAIT line')
            wrapped = True
        pos = ((v - 256) if wrapped else v) << 8 | 1
        if regs is None:
            lines.append('        dc.w $%04X,$FFFE                    ; y=72: animated slot' % pos)
            lines.append('cop_raster_color:')
            lines.append('        dc.w COLOR00,$013                   ; animated by UpdateRaster each frame')
        else:
            body = ','.join('%s,$%04X' % (r, val) for r, val in regs)
            lines.append('        dc.w $%04X,$FFFE,%s' % (pos, body))
    lines.append('        dc.w $FFFF,$FFFE')
    return '\n'.join(lines)

def recip_star():
    # 256 entries: round(PROJ_F * 256 / z) for z = 32..255 (z below 32 never occurs).
    vals = [0] * 32 + [int(round(128 * 256 / z)) for z in range(32, 256)]
    return '\n'.join('        dc.w ' + ','.join('%d' % v for v in vals[i:i + 16]) for i in range(0, 256, 16))

def recip_wire():
    # 416 entries: round(WIRE_D * 256 / zc) for zc = 150..415 (the distance stays about 227..373).
    vals = [0] * 150 + [int(round(220 * 256 / z)) for z in range(150, 416)]
    return '\n'.join('        dc.w ' + ','.join('%d' % v for v in vals[i:i + 16]) for i in range(0, 416, 16))

def sintab():
    vals = [int(round(127 * math.sin(2 * math.pi * k / 256))) for k in range(256)]
    return '\n'.join('        dc.w ' + ','.join('%d' % v for v in vals[i:i + 16]) for i in range(0, 256, 16))

if __name__ == '__main__':
    print({'copper': copper, 'sintab': sintab, 'recip_star': recip_star, 'recip_wire': recip_wire}[sys.argv[1]]())
