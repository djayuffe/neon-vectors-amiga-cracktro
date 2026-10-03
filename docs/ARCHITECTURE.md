# Architecture

## Target

A **PAL OCS/ECS, 68000** production. The 320×256 display window, the 50 Hz tracker tick and the
frame-sync line are PAL-specific. It makes no claim about NTSC timing; on a 262-line frame it
does not hang but is mistimed (see "Frame pipeline").

## Module layout

The source is split into one file per concern. `src/main.s` is the assembler entry point; it
defines the EQU block, includes every other file, and holds the runtime state and data tables.
The include order matters: VASM 1.8f's `-kick1hunks` mode is single-pass, so every function
must be defined before its first call site. The `tools/splice.py` pre-processor inlines all
`include` directives into a single translation unit before assembly, which removes the
ordering constraint for the assembler but the logical dependency order is preserved in the
source.

| File | Section | Contents |
|---|---|---|
| `src/hardware.i` | — | Custom-chip offsets, DMACON/INTENA bit EQUs, LVO vectors, GfxBase offsets |
| `src/main.s` | EQU, code, data | Layout constants, `include` chain, runtime state, tables (`reloc_table`, `sintab`, `recip_*`, `wave_tab`, `floor_base`, `bar_colors`, `ring_tab`, `ball_bitmaps`, `verts`, `edges`, `scroll_text`, `raster_colors`) |
| `src/system.s` | code | `AllocChipMem`, `BeamLine`, `WaitFrameSync`, `WaitLines`, `include` of scene files, `_start` (takeover + main loop + teardown) |
| `src/copper.s` | code | `PatchCopper`, `WireSwap` |
| `src/chipdata.s` | chipdata | Copper list, sprite pages, screen buffers, `logo_data`, `font_data`, `audio_silence`, `mod_data` |
| `src/scene_logo.s` | code | `ClearScreen`, `DrawLogo`, `CopyLogoPlane` |
| `src/scene_stars.s` | code | `Rand`, `InitStars`, `UpdateStars` |
| `src/scene_wire.s` | code | `BlitWait`, `DrawWire`, `Mul7`, `CalcMatrix`, `TransformVerts`, `BlitLine` |
| `src/scene_scroller.s` | code | `UpdateScroller` |
| `src/scene_sprites.s` | code | `InitSprites`, `SinCos`, `UpdateSprites` |
| `src/scene_copperbars.s` | code | `UpdateWave`, `UpdateBars`, `UpdateRaster` |
| `src/modplayer.s` | code, data | `MOD_Init`, `MOD_Tick`, `MOD_Stop`, MOD player state |

### Include order and the VASM single-pass problem

VASM 1.8f with `-kick1hunks` performs a single left-to-right pass over the source. A `jsr` or
`bsr` to a symbol that has not yet been defined produces a "reloc type 2, size 16 not
supported" error — the assembler cannot emit a 16-bit displacement to an unknown address and
has no second pass to fix it up. (VASM 2.0f resolves forward references; this project was
built against 1.8f.)

The solution is two-fold:

1. **Logical order in the source.** In `system.s`, the helper functions
   (`AllocChipMem`, `BeamLine`, `WaitFrameSync`, `WaitLines`) appear before the scene
   `include` lines, which appear before `_start`. Within the scene files, each file defines
   its own helpers before its own call sites (e.g. `scene_wire.s` defines `BlitWait`,
   `Mul7`, `CalcMatrix`, `TransformVerts`, `BlitLine` before `DrawWire` calls them).

2. **`tools/splice.py`.** Before assembly, the Makefile runs
   `python3 tools/splice.py src/main.s build/merged.s`, which recursively inlines all
   `include` directives into a single flat file. VASM then sees one translation unit with
   no include boundaries. The splice is pure text: no code generation, no reordering.

All cross-function calls use `jsr` (absolute addressing) rather than `bsr` (PC-relative,
±32 KiB) to avoid any displacement-range issues.

### The chipdata split

`copper.s` contains only the code (`PatchCopper`, `WireSwap`). The chip RAM payload
(Copper list, sprite pages, screen buffers, logo, font, silence word, MOD) lives in
`chipdata.s`, which starts with `section chipdata,data_c`. This separation is essential:
if the chipdata section declaration appeared before the scene `include` lines, all
subsequent scene code would be emitted into the chipdata hunk. By placing `chipdata.s`
after all the scene includes in `system.s`, the code section is complete before the
chipdata section begins.

## Startup and ownership

1. Save all CPU registers (`movem.l d0-d7/a0-a6`).
2. Open `graphics.library` with `OpenLibrary` (name in `a1`, version 0 in `d0`). Save `GfxBase->ActiView`
   (offset 34) and `GfxBase->copinit` (offset 38), the system Copper start list. `COP1LC` is
   write-only and cannot be read back, so `copinit` is the documented source.
3. Allocate, verify, copy and re-base the chip-RAM payload (next section). This happens with
   interrupts still enabled because `AllocMem` must not be called under `Disable()`.
4. `LoadView(NULL)`, two `WaitTOF`, `OwnBlitter`, `WaitBlit` — still with interrupts on, since
   `WaitTOF` depends on the vertical-blank interrupt.
5. Snapshot `DMACONR`, `INTENAR`, `ADKCONR`.
6. `Forbid()` then `Disable()`, in that order.
7. Clear `INTENA`/`INTREQ`, stop all DMA, clear all `ADKCON` bits.
8. Initialise screen, logo, stars, Copper pointers and the MOD player; install the Copper list
   and enable master + bitplane + Copper + blitter + sprite DMA. **Audio DMA stays off** — a channel
   enabled before it has a sample would play 128 KB of memory as noise; each channel is switched on
   by the first note that uses it.

On exit: wait for the blitter to go idle, stop Paula, mask interrupts and stop all DMA,
`LoadView(old view)`, point `COP1LC` at `copinit` and strobe `COPJMP1`, restore
`ADKCON`/`INTENA`/`DMACON` from the snapshots as SET writes, then `Enable()` and `Permit()`
(in that order), two `WaitTOF`, `DisownBlitter`, free the chip block, close the library and
restore all registers. Return code 0 (20 if startup failed).

The register restore comes *before* the waits on purpose: `WaitTOF` sleeps until the
vertical-blank interrupt fires, and that interrupt is still masked from the takeover until
`INTENA` is restored. Waiting first hangs the machine.

All library calls pass the library base in `a6`, as every Amiga library expects.
Kickstart's Exec does not read it, but AROS's does, so a base in any other register
crashes there.

Why BPLCON0/1/2 and the modulos are not restored by hand: `LoadView` and the restarted
system Copper list write them on the next frame; a value captured while another View was
active is not a safer source.

## Chip memory and re-basing

Copper, bitplanes and Paula DMA must be in chip RAM. With `-kick1hunks` the loader may
place the hunk in ordinary memory, so the program does the work itself:

1. `AllocMem(d0 = size, d1 = MEMF_CHIP)` for the whole contiguous payload block.
2. `TypeOfMem(a1 = block)` to confirm chip RAM; otherwise `FreeMem` and fail with code 20.
3. `CopyMem(a0 = source, a1 = dest, d0 = size)`.
4. Rewrite each of the twelve longwords in `reloc_table` as `base + (assembled − block start)`.

The block holds, in order (defined in `chipdata.s`): the Copper list, sprite pages,
a spare word, four plane-sized screen buffers (plane 0, two wireframe buffers, plane 2),
logo, font, the `$8080` silence word and the MOD. Code reaches them only through
`ptr_screen`, `ptr_logo`, `ptr_font`, `ptr_silence`, `ptr_mod`, `ptr_copper`,
`ptr_cop_bpl1`, `ptr_raster`, `ptr_wave`, `ptr_bars`, `ptr_sprites`, `ptr_cop_spr`
(slots in `reloc_table`). A direct reference to one of those labels would keep pointing
at the loaded hunk, so `tools/validate.py` rejects it, and the emulation test verifies
that the original hunk is never modified.

All other data (saved registers, tables, the MOD player state) lives in an ordinary data
hunk and is addressed absolutely; the hunk loader relocates those references.
PC-relative addressing cannot reach another hunk and can never be a destination, so it
is not used for data.

### Relocation table

`reloc_table` (12 longs, in `src/main.s` data section):

| Offset | Label | Contents |
|---|---|---|
| +0 | `screen` | 6 × 10240 byte plane buffers |
| +4 | `logo_data` | 10240 byte logo (4 × 2560 byte bitplanes) |
| +8 | `font_data` | 760 byte font (95 × 8) |
| +12 | `audio_silence` | `$8080` Paula silent terminal word |
| +16 | `mod_data` | 11632 byte `M.K.` module |
| +20 | `copper` | Copper list start |
| +24 | `cop_bpl1` | BPL1PTH/PTL pointer pairs |
| +28 | `cop_raster_color` | Animated COLOR00 MOVE pair |
| +32 | `cop_wave` | Per-row BPLCON1 wave values (64 × 16 bytes) |
| +36 | `cop_bars` | Floor bar colour values (34 × 8 bytes) |
| +40 | `sprites` | 8 × 80 byte sprite pages |
| +44 | `cop_spr` | Sprite pointer words |

## Copper list

A sequence of `MOVE` register/value pairs ending with the `$FFFF,$FFFE` stall. From
`cop_bpl1` the six bitplane-pointer pairs put the register words at byte offsets
0/4/8/12/16/20 and the data words that `PatchCopper` writes at 2/6, 10/14 and 18/22.

A WAIT is two words: position with bit 0 set, then mask with bit 0 clear and bit 15 set
(blitter-finished ignored). After the header, palette, and pointer pairs the list is a
long run of `WAIT line, MOVE COLOR00/COLOR01, ...` entries generated by
`tools/gen_tables.py copper`: a gradient behind and through the logo every two lines,
the mid-star colour and a soft glow in the middle band, the scroller strip's frame lines
and gradient, and floor bars below. The 8-bit vertical position cannot express display
lines above 255, so one `WAIT $FFDF,$FFFE` wraps the counter and later WAITs mean
256 + n. `cop_raster_color` is the `COLOR00` pair at row 72 that `UpdateRaster`
overwrites once per frame.

## Scene framework

Every scene module exposes one or more functions called by the main loop in a fixed
order. The contract is:

- **Init** (once, after `ClearScreen`): `InitStars`, `InitSprites`. These set up
  per-object state (star positions, ball ring phase).
- **Update** (once per frame): `UpdateWave`, `UpdateBars`, `UpdateSprites`,
  `UpdateRaster`, `UpdateStars`, `UpdateScroller`, `DrawWire`. These rewrite the
  frame's output.
- **WireSwap** (once per frame, before all Updates): flips the wireframe buffer
  index and patches the Copper bitplane pointers.

### Beam-slack contract

Each `Update_*` must finish before the beam reaches the top line of the region it
writes. The emu test enforces this per scene via symbol marks:

| Scene | Must finish before beam reaches | Deadline margin (worst frame) |
|---|---|---|
| `UpdateWave`/`UpdateBars`/`UpdateRaster` | line 44+72 (logo bottom) | ~19 000 cycles |
| `UpdateSprites` | line 44+44+56 (ring top) | ~18 000 cycles |
| `UpdateStars` | line 44+76 (starfield top) | ~64 000 cycles |
| `UpdateScroller` | line 44+200 (scroller top) | (ample) |
| `DrawWire` | next frame (double-buffered) | N/A |

All scenes read the global `frame_no` (advanced once per loop) and the re-based
`ptr_*` slots; no scene touches another scene's state. Scenes are CPU-only except
`DrawWire`/`BlitLine` (blitter) and the Copper-slot writers (plain memory writes to
the Copper list, always below the beam).

## Frame pipeline

`BeamLine` reads `VPOSR` and `VHPOSR` with a single long access (they are adjacent,
so the pair cannot straddle a line change) and returns the 9-bit line number in `d0`.
`WaitFrameSync` first leaves the sync zone, then waits for line ≥ 300, the first line
below the display window (`DIWSTOP` = line 300). One iteration of the main loop
therefore equals one PAL frame, giving a 50 Hz tick rate on both the 312- and
313-line frames. Each iteration runs, in order:

1. `BlitWait`, then `WireSwap` — show the wireframe buffer that was finished last frame;
2. `UpdateWave` and `UpdateBars` — rewrite the logo's `BPLCON1` rows and the floor's
   colour rows in the Copper list (they must finish before the beam reaches the logo);
3. `UpdateSprites` — position the ball ring on the sprite channels;
4. `UpdateRaster` — rewrites the animated `COLOR00` slot;
5. `UpdateStars` — erase, advance and redraw the 3D starfield;
6. `UpdateScroller` — every second frame, shift the strip one pixel and insert a column;
7. `MOD_Tick` — one tracker tick (a row every 6 ticks), after the time-critical drawing;
8. `DrawWire` — clear the hidden buffer's band with the blitter, rotate/project the
   icosahedron, draw 30 edges with the blitter;
9. test the left mouse button.

**Why each thing is (or is not) double-buffered.** The wireframe takes most of a frame
to draw (30 blitter lines), so it alone is double-buffered. The Copper rows for the
wave and the bars are rewritten first and finish before the beam reaches the logo;
the stars finish before the beam reaches the starfield band; the scroller is shifted
before the beam reaches its strip. `tools/emu_test.py` measures all the deadlines.

**CPU budget** (emulated 68000, no DMA contention, blitter time not included since it
runs in parallel): about 77 000 cycles per frame on average, 84 000 worst case, i.e.
54–59 % of a 142 000 cycle frame. The main costs are the starfield (~25 000), the
wireframe (~32 000 for 30 edges), the wave and bars (~9 000) and the scroller
(~5 000 averaged over two frames).

If the beam wraps before line 300 is reached — a 262-line NTSC frame — the wait ends
at the wrap instead of hanging with interrupts disabled.

## Wireframe: icosahedron

The wireframe object is a **regular icosahedron** — 12 vertices, 30 edges, every
vertex degree 5. The vertices are the classical set `(0, ±1, ±φ)`, `(±1, ±φ, 0)`,
`(±φ, 0, ±1)` scaled to half-size 42 and rounded to integers:

```
(0,  ±26,  ±42)   4 vertices
(±26, ±42,  0)   4 vertices
(±42,  0,  ±26)   4 vertices
```

24 of the 30 edges have squared length 2696 and 6 have 2704 — a 0.15 % spread, the
closest regular integer icosahedron at this scale. The validator checks this: 12
vertices, 30 edge pairs, every vertex degree 5, edge length spread ≤ 0.5 %.

Per frame:

1. `DrawWire` selects the hidden buffer (opposite of `wire_front`).
2. The blitter clears the band (D-only blit, minterm 0) while the CPU works.
3. `CalcMatrix` builds one 3×3 rotation `Rz(k)·Ry(2k)·Rx(k)` from 7-bit sine/cosine
   tables, scaled by 128. The single `ang` counter drives all three angles.
4. The motion path: `wire_cx = MID_CX + (sin(k)·WIRE_SWAY)>>7` (sway),
   `wire_zoff = WIRE_ZOFF + (sin(2k)·WIRE_ZOOM)>>7` (breathe).
5. `TransformVerts` rotates and perspective-projects the 12 vertices. Because every
   coordinate is 0 or ±42, the rotation is a sum of ±columns of the pre-computed
   `mat · 42` products — no per-vertex multiplication. Perspective:
   `screen = centre + r · WIRE_D / (z + wire_zoff)` via a reciprocal table.
6. `BlitLine` draws each of the 30 edges with the blitter in **line mode**. The
   registers that never change between lines (A/B data, masks, C/D modulo) are set
   once per frame before the edge loop.
7. Next frame `WireSwap` points the Copper at the finished buffer, so the display
   never shows a half-drawn picture.

**Line mode.** The octant bits in `BLTCON1` come from the Hardware Reference Manual's
table 6-3 (`octants` in the source), `dmaj`/`dmin` are the larger/smaller of |dx|,
|dy|, and:

```
BLTAPT = 4·dmin − 2·dmaj    BLTAMOD = 4·(dmin − dmaj)    BLTBMOD = 4·dmin
BLTSIZE = ((dmaj + 1) << 6) | 2    BLTCON0 = (x1 & 15) << 12 | $0BCA
```

`ONEDOT` is left **clear**: it is for area-fill edges, and with it set shallow lines
come out with gaps. There is no clipping: the object is sized to stay inside its
120-line band, and the emulation test asserts it.

## Display

- 320×256 low resolution PAL, four bitplanes, 40 bytes per line; 21 words fetched per
  line with modulo −2 and planes starting one word early (for the per-row `BPLCON1`
  scroll)
- Plane 0: logo, mid stars, scroller; plane 1: wireframe (double-buffered);
  plane 2: far/near stars; plane 3: wireframe (double-buffered, second buffer)
- Copper-programmed DIW/DDF, bitplane pointers, palette, and per-row colour and scroll
  changes

## Constraints

No OS calls occur in the running loop. The CPU draws the stars and scroller; the
blitter clears the wireframe band and draws its lines (it is owned for the whole run
so no other task can use it). No interrupt handlers are installed. Only 68000
instructions and addressing modes are used. Cross-function calls use `jsr` (absolute)
rather than `bsr` (PC-relative) to work within VASM 1.8f's single-pass assembler.

## Audio ownership

The intro takes Paula exclusively and leaves audio DMA off on exit: the previous
audio-DMA state cannot be restored against changed channel registers without risking
noise, so the restored `DMACON` mask (`DMAF_SYSTEM`, `$07F0`) excludes the four audio
bits.

## Build pipeline

```
make
├── tools/generate_assets.py     (only if the generator changed: logo.raw, font.raw, neon.mod)
├── tools/splice.py              (inline all includes → build/merged.s)
├── tools/validate.py            (asset + source checks; gates the build)
├── vasmm68k_mot -m68000 -kick1hunks -Fhunkexe -nosym -I./src -o build/neon_vectors build/merged.s
└── tools/hunkcheck.py           (structural parse of the executable)
```

The splice step is the key difference from a straightforward VASM invocation. Without
it, VASM 1.8f cannot resolve `jsr` targets across `include` boundaries in
`-kick1hunks` mode. The spliced file is byte-identical to what VASM would see if it
performed its own include expansion (it is a pure text splice with no code
generation).
