#!/usr/bin/env python3
"""Deterministically generate every binary asset used by NEON VECTORS.
No host fonts, Pillow, timestamps, randomness without a fixed seed, or external tools.
"""
from pathlib import Path
import math, struct, random, zlib
ROOT=Path(__file__).resolve().parents[1]
A=ROOT/'assets'; A.mkdir(exist_ok=True)

# 5x7 glyphs. Lowercase is intentionally rendered as uppercase for the demo font.
G={
' ':['00000']*7,'!':['00100','00100','00100','00100','00100','00000','00100'],
'-':['00000','00000','00000','11111','00000','00000','00000'],
'.':['00000','00000','00000','00000','00000','00110','00110'],
'/':['00001','00010','00100','01000','10000','00000','00000'],
':':['00000','00110','00110','00000','00110','00110','00000'],
'?':['01110','10001','00001','00010','00100','00000','00100'],
'0':['01110','10001','10011','10101','11001','10001','01110'],
'1':['00100','01100','00100','00100','00100','00100','01110'],
'2':['01110','10001','00001','00100','00100','01000','11111'],
'3':['11110','00001','00001','01110','00001','00001','11110'],
'4':['00010','00110','01010','10010','11111','00010','00010'],
'5':['11111','10000','10000','11110','00001','00001','11110'],
'6':['01110','10000','10000','11110','10001','10001','01110'],
'7':['11111','00001','00010','00100','10000','01000','01000'],
'8':['01110','10001','10001','01110','10001','10001','01110'],
'9':['01110','10001','10001','01111','00001','00001','01110'],
'A':['01110','10001','10001','11111','10001','10001','10001'],
'B':['11110','10001','10001','11110','10001','10001','11110'],
'C':['01111','10000','10000','10000','10000','10000','01111'],
'D':['11110','10001','10001','10001','10001','10001','11110'],
'E':['11111','10000','10000','11110','10000','10000','11111'],
'F':['11111','10000','10000','11110','10000','10000','10000'],
'G':['01111','10000','10000','10111','10001','10001','01111'],
'H':['10001','10001','10001','11111','10001','10001','10001'],
'I':['01110','00100','00100','00100','00100','00100','01110'],
'J':['00001','00001','00001','00001','10001','10001','01110'],
'K':['10001','10010','10100','11000','10100','10010','10001'],
'L':['10000','10000','10000','10000','10000','10000','11111'],
'M':['10001','11011','10101','10101','10001','10001','10001'],
'N':['10001','11001','10101','10011','10001','10001','10001'],
'O':['01110','10001','10001','10001','10001','10001','01110'],
'P':['11110','10001','10001','11110','10000','10000','10000'],
'Q':['01110','10001','10001','10001','10101','10010','01101'],
'R':['11110','10001','10001','11110','10100','10010','10001'],
'S':['01111','10000','10000','01110','00001','00001','11110'],
'T':['11111','00100','00100','00100','00100','00100','00100'],
'U':['10001','10001','10001','10001','10001','10001','01110'],
'V':['10001','10001','10001','10001','10001','01010','00100'],
'W':['10001','10001','10001','10101','10101','10101','01010'],
'X':['10001','10001','01010','00100','01010','10001','10001'],
'Y':['10001','10001','01010','00100','00100','00100','00100'],
'Z':['11111','00001','00010','00100','10000','10000','11111'],
}

def glyph8(ch):
    key=ch.upper()
    rows=G.get(key)
    if rows is None:
        # Deterministic visible fallback for printable characters not used by the demo.
        v=ord(ch)&0x7f
        rows=['11111']+[f'{((v>>(r%7))|((v<<(7-r))&0x7f))&0x1f:05b}' for r in range(5)]+['11111']
    out=[]
    for r in range(7):
        bits=rows[r]
        b=0
        for x,c in enumerate(bits):
            if c=='1': b |= 1 << (6-x)  # centered in 8 pixels, columns 1..5
        out.append(b)
    out.append(0)
    return bytes(out)

# ---------- deterministic 8x8 font ASCII 32..126 ----------
fraw=b''.join(glyph8(chr(c)) for c in range(32,127))
(A/'font.raw').write_bytes(fraw)

# ---------- deterministic planar logo ----------
# A 320x64 sixteen colour image drawn procedurally by tools/logo_art.py (distance-field letters
# with bevel lighting, extrusion shadow, chiselled subtitle, wing ornaments), stored as four
# bitplanes of 40 bytes per row, one after the other (2560 bytes each).
import sys
sys.path.insert(0, str(Path(__file__).resolve().parent))
import logo_art
W, H = logo_art.W, logo_art.H
img = logo_art.build()
raw = b''.join(logo_art.to_planes(img))
(A/'logo.raw').write_bytes(raw)

def png_chunk(tag,data):
    return struct.pack('>I',len(data))+tag+data+struct.pack('>I',zlib.crc32(tag+data)&0xffffffff)
scale=2
scan=b''.join(b'\x00'+bytes(r) for r in logo_art.preview_rgb(img,scale))
png=b'\x89PNG\r\n\x1a\n'+png_chunk(b'IHDR',struct.pack('>IIBBBBB',W*scale,H*scale,8,2,0,0,0))+png_chunk(b'IDAT',zlib.compress(scan,9))+png_chunk(b'IEND',b'')
(A/'logo_preview.png').write_bytes(png)

# ---------- deterministic ProTracker MOD (refactored) ----------
# 8 patterns x 64 rows, 4 channels, songlen 8, order 0..7, speed 6 (125 BPM).
# Header is exactly 1084 bytes: 20 title + 31*30 instruments + 1 songlen +
# 1 speed + 128 order + 4 "M.K." - so "M.K." sits at 1080..1083 and the
# pattern base at 1084 is 4 aligned (the player finds it by searching for
# the marker). Only effects 0 (note), C (volume), F (speed) and A (slide up)
# are emitted; the player and the validator agree on that whitelist.
#
# The 31 instruments are all valid: 5 real samples plus 26 two-byte silence
# entries, so the player's 31-entry sample pointer table is fully populated.
MOD_TITLE='NEON VECTORS MOD II'
MOD_SONGLEN=8
MOD_SPEED=6
MOD_NPATS=8
MOD_NROWS=64

# Standard 12 bit Amiga MOD period table, C-1 (856) down to B-4 (113).
MOD_PERIODS={}; MOD_NAMES=['C','C#','D','D#','E','F','F#','G','G#','A','A#','B']; MOD_BASE=[856,808,762,720,678,640,604,570,538,508,480,453]
for octv in range(1,5):
    for i,n in enumerate(MOD_NAMES): MOD_PERIODS[f'{n}{octv}']=max(113,MOD_BASE[i]>>(octv-1))
def _u8(v): return 0 if v<0 else 255 if v>255 else v
# Paula plays 8 bit samples as unsigned, so every waveform is centred on 128.
# Writing the signed value straight out (or masking it with &255) puts the
# whole sample near full scale and produces an audible DC step in the loop.
def pcm_sine(n=128,amp=80): return bytes(_u8(128+int(amp*math.sin(2*math.pi*i/n))) for i in range(n))
def pcm_square(n=128,amp=70): return bytes(_u8(128+amp if i<n//2 else 128-amp) for i in range(n))
def pcm_kick(n=512):
    out=[]; ph=0.0
    for i in range(n):
        t=i/n; ph+=2*math.pi*(90*(1-t)+25)/8000; out.append(_u8(128+int(110*math.exp(-6*t)*math.sin(ph))))
    return bytes(out)
def pcm_hat(n=256,seed=68000):
    rng=random.Random(seed)
    return bytes(_u8(128+int(90*math.exp(-5*i/n)*rng.uniform(-1,1))) for i in range(n))
def pcm_noise_lp(n=128,seed=68001):
    rng=random.Random(seed)
    out=[]; lp=0.0
    for i in range(n):
        lp+=0.25*(rng.uniform(-1,1)-lp)
        out.append(_u8(128+int(80*math.exp(-5*i/n)*lp)))
    return bytes(out)
# (name, data, volume, loop_start, loop_len) - lengths are in words, loop_len 1 = one-shot.
MOD_INSTRUMENTS=[
    ('BASS',pcm_square(),64,0,64),   # 128 byte square loop, 8th note roots
    ('LEAD',pcm_sine(),64,0,64),     # 128 byte sine loop, arpeggio + slides
    ('KICK',pcm_kick(),64,0,1),      # decaying 90->25 Hz sweep, one-shot
    ('HAT',pcm_hat(),48,0,1),        # decaying white noise, one-shot
    ('NLP',pcm_noise_lp(),20,0,1),   # lowpassed noise accent, one-shot
]
def _inst_header(name,data,vol,ls,ll):
    # The on-disk sample data must be exactly len(data) bytes: the file stores
    # the samples back to back with no padding, and the player walks them by
    # the header lengths, so an even pad byte here would shift every later
    # sample out of alignment.
    assert len(data)%2==0,'odd sample length breaks the back-to-back layout'
    return name.encode()[:22].ljust(22,b' ')+struct.pack('>HBBHH',len(data)//2,0,vol,ls,ll)
def _mod_instruments():
    headers=[]; datas=[]
    for name,data,vol,ls,ll in MOD_INSTRUMENTS:
        headers.append(_inst_header(name,data,vol,ls,ll)); datas.append(data)
    silence=bytes([128,128])
    while len(headers)<31:
        headers.append(_inst_header('SIL',silence,0,0,1)); datas.append(silence)
    return headers,datas
def _ev(period=0,sample=0,fx=0,param=0):
    return bytes([(sample&0xF0)|((period>>8)&15),period&255,((sample&15)<<4)|(fx&15),param&255])
# Am - F - C - G, repeated over the second 4-bar group.
MOD_BASS=['A1','F1','C2','G1','A1','F1','C2','G1']
MOD_CHORDS=[['A3','C4','E4'],['F3','A3','C4'],['C4','E4','G4'],['G3','B3','D4'],
            ['A3','C4','E4'],['F3','A3','C4'],['C4','E4','G4'],['G3','B3','D4']]
MOD_SLIDES=[1,2,3,4,5,1,2,3,4,5,1,2]
def _mod_pattern(pat):
    root=MOD_PERIODS[MOD_BASS[pat]]
    chord=[MOD_PERIODS[n] for n in MOD_CHORDS[pat]]
    bar=pat%4
    pb=bytearray()
    for row in range(MOD_NROWS):
        in_bar=row%16
        # ch1: 8th notes on the chord root; pattern 0 row 0 also sets the speed.
        if row%2==0:
            c1=_ev(root,1,0xF,MOD_SPEED) if pat==0 and row==0 else _ev(root,1)
        else:
            c1=_ev()
        # ch2: 16th arpeggio on beats 1 and 3, cycling root/third/fifth; the
        # second group adds an A0x slide-up on the last note of each bar.
        c2=_ev()
        if in_bar in (0,4,8,12):
            tone=chord[(in_bar//4)%3]
            if pat>=4 and in_bar==12:
                c2=_ev(tone,2,0xA,MOD_SLIDES[bar*2+(row//16)%2])
            else:
                c2=_ev(tone,2)
        # ch3: kick on rows 0,8,16,...,56.
        c3=_ev(MOD_PERIODS['C2'],3) if row%8==0 else _ev()
        # ch4: off-beat hat with a C20 volume on the row before; an accented
        # lowpassed noise on rows 4,12,20,... of every 8.
        if row%4 in (2,6) and row+1<MOD_NROWS:
            c4=_ev(MOD_PERIODS['C3'],4,0xC,20)
        elif row%4 in (2,6):
            c4=_ev()
        elif row%4==0 and row%8==4:
            c4=_ev(MOD_PERIODS['C4'],5)
        else:
            c4=_ev()
        pb+=c1+c2+c3+c4
    return bytes(pb)
def build_mod():
    headers,datas=_mod_instruments()
    header=bytearray(MOD_TITLE.encode()[:20].ljust(20,b' '))
    for h in headers: header+=h
    header+=bytes([MOD_SONGLEN,MOD_SPEED])
    header+=bytes(list(range(MOD_NPATS))+[0]*(128-MOD_NPATS))
    header+=b'M.K.'
    assert len(header)==1084,len(header)
    pats=b''.join(_mod_pattern(p) for p in range(MOD_NPATS))
    return bytes(header+pats+b''.join(datas))
mod=build_mod()
(A/'neon.mod').write_bytes(mod)
print(f'generated logo={len(raw)} font={len(fraw)} mod={len(mod)} bytes')
