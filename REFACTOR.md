# REFACTOR.md — engine / gfx / music ground-up rewrite

Status: SPEC (input to the implementation). Supersedes `FULL_IMPLEMENTATION_PLAN.md`,
`PHASE2_*`, `plan_aga.md` and the "Phase 2/3/4" half-built features, which are dropped.

Goal: one coherent, small, correct cracktro engine instead of an accreted one.
Everything below is a contract the implementation, the validator and the emulated-68000
test must all agree on. Where this spec and an old document disagree, this spec wins.

---

## 1. Non-negotiable invariants (keep, verified behaviour)

These are what makes the program safe on real hardware. The refactor keeps them exactly:

- **Takeover/restore** (`_start`): OpenLibrary(graphics.library, a1/d0) → save
  ActiView + copinit → `AllocChipMem` (AllocMem MEMF_CHIP, TypeOfMem must say chip,
  CopyMem the whole `data_c` block, rebase the `reloc_table` longs) → LoadView(NULL) →
  2×WaitTOF → OwnBlitter → WaitBlit → snapshot DMACONR/INTENAR/ADKCONR → Forbid →
  Disable → clear INTENA/INTREQ/DMACON/ADKCON ($7FFF) → install → main loop.
  Teardown in exact reverse order: BlitWait → MOD_Stop → clear all DMA/ints →
  LoadView(old) → COP1LCH←old_copper, COPJMP1←0 → restore ADKCON/INTENA/DMACON as
  SET/CLR (audio deliberately left off) → Enable before Permit → 2×WaitTOF →
  DisownBlitter → FreeMem → CloseLibrary. Return 0 ok / 20 on alloc failure.
- **a6 = CUSTOM** in every chipset helper; **a6 = ExecBase (4.w)** around every
  `jsr LVO_xxx(a6)`.
- **Chip RAM discipline**: code may never address a chipdata label directly; only the
  re-based `ptr_*` slots. One contiguous `data_c` block, one CopyMem, one reloc table.
- **Frame sync**: `WaitFrameSync` two-phase edge detect at `FRAME_SYNC_LINE` (300);
  exactly one iteration per PAL frame; NTSC must not hang (wrap branch).
- **Double-buffered wireframe band**: only the hidden buffer is ever blitted; the
  displayed buffer flips once per frame via `PatchCopper` (BPL1/BPL2/BPL3/BPL4 +
  BPL1MOD/BPL2MOD = $FFFE, planes start 2 bytes early for the BPLCON1 fetch word).
- **Copper list**: one flat list, WAIT+MOVE pairs only (no COPJMP), the `$FFDF,$FFFE`
  wrap park, terminated by `$FFFF,$FFFE`. The per-row rewrite slots are fixed-stride
  blocks (`cop_wave` 16 B/row, `cop_bars` 8 B/row) written below the beam.
- **Paula**: audio DMA never on at startup; each channel enabled by its first note via
  the clear-bit → write regs → re-enable (latches loc+len) → install loop/terminal
  sequence; one-shots loop over the chip `$8080` silence word.
- **Exit state** the emu test verifies: return code, all registers preserved, no chip
  allocs left, library closed, LoadView [NULL, old], COP1LC restored, DMACON/INTENA/
  ADKCON restored (audio bits clear), scheduler order Forbid/Disable/Enable/Permit,
  code hunk byte-identical, no link-time chip hunk modification.

## 2. What changes

### 2.1 File layout

| File | Contents |
|---|---|
| `src/hardware.i` | custom-chip offsets, DMACON/INTENA bit EQUs, LVO vectors, GfxBase offsets (unchanged contract) |
| `src/system.s` | `_start`, AllocChipMem, relocation pass, ChipKill/ChipRestore helpers, BeamLine, WaitFrameSync, WaitLines, teardown |
| `src/copper.s` | the Copper list (chipdata section), incl. `copper:`, `cop_bpl1:`, palette, `cop_spr:`, `cop_wave:`, `cop_raster_color:`, wrap, `cop_bars:`, park, `sprites:` pages, `screen:`, incbins |
| `src/scene_logo.s` | `DrawLogo` (one-shot blit of the 4 logo planes into the screen block, logo rows only) |
| `src/scene_stars.s` | `InitStars`, `UpdateStars`, `Rand` |
| `src/scene_wire.s` | `CalcMatrix`, `Mul7`, `TransformVerts`, `DrawWire` (orchestrates: hidden-buffer select → band clear → angles/sway/breathe → transform cube+octa → draw edges), `BlitWait`, `BlitLine`, `octants` |
| `src/scene_scroller.s` | `UpdateScroller` (font, ROXL shift chain) |
| `src/scene_sprites.s` | `InitSprites`, `SinCos`, `UpdateSprites` (ball ring, depth sort, page patch) |
| `src/scene_copperbars.s` | `UpdateWave`, `UpdateBars`, `UpdateRaster` |
| `src/main.s` | EQU block (layout constants), the main loop (ordered scene calls + MOD_Tick + mouse-exit), runtime state, the tables (`reloc_table`, `sintab`, `recip_*`, `wave_tab`, `floor_base`, `bar_colors`, `ring_tab`, `ball_bitmaps`, `verts`, `edges`, `scroll_text`, `raster_colors`), `include` of the above + modplayer |
| `src/modplayer.s` | `MOD_Init`, `MOD_Tick`, `MOD_Stop` + internal row engine (restructured per §3) |

Removed: `src/phase2c_drawsolid.s` (orphan), `WaitLines` stays (used by modplayer),
and ALL of the dead Phase-2/3/4 machinery: `SortFaces`, `DrawSolid` (quad outlines),
`UpdateSphereShading`, `UpdateParticles`, `face_order`, `sphere_*`, `particles`,
`cube_verts` (±40), `octahedron_verts`, `light_x/y/z` (light becomes an inline EQU
triple), `octahedron_shading` (the octahedron is a wireframe — no per-face shading).
No `#include` of the phase files; they are deleted.

main.s `include`s the scene files after the EQU block and before the data section, so
labels resolve; the assembler is still invoked on `src/main.s` alone (VASM `-I./src`).

### 2.2 Scene framework

- Every scene module exposes `Init_<name>` (run once after ClearScreen) and
  `Update_<name>` (run once per frame). The main loop calls them in a FIXED order:
  `WireSwap` → `UpdateWave` → `UpdateBars` → `UpdateSprites` → `UpdateRaster` →
  `UpdateStars` → `UpdateScroller` → `MOD_Tick` → `DrawWire`.
- **Beam-slack contract** (the emu test enforces it per scene): each `Update_*` must
  finish before the beam reaches the top line of the region it writes in vblank:
  sprites < line 44+56, stars < 44+76, scroller < 44+200, wave/bars/raster < 44+72.
  The scene functions are timed by the harness via symbol marks (see §5 hooks).
- All scenes read the global `frame_no` (advanced once per loop) and the re-based
  `ptr_*` slots; no scene touches another scene's state.
- Scenes are CPU-only except `DrawWire`/`BlitLine` (blitter) and the Copper-slot
  writers (plain memory writes to the Copper list, always below the beam).

### 2.3 Wireframe scene (new object)

- **Model**: a regular icosahedron — 12 vertices, 30 edges, all edges equal length.
  Vertices at `(0, ±1, ±φ)`, `(±1, ±φ, 0)`, `(±φ, 0, ±1)` scaled to half-size 42
  (integer coords, φ ≈ 1.618 → use the exact integer set (±11, ±18) pairs that
  approximate it; the reference model in the emu test uses the SAME table via the
  hunk symbol `verts`). Keep the object inside its 120-line band (no clipping).
- **Motion**: single 3×3 rotation `Rz(k)·Ry(2k)·Rx(k)` (k = frame, 7-bit fixed,
  amplitude-127 sin tables) + sway `wire_cx = MID_CX + (sin(k)·WIRE_SWAY)>>7` and
  breathe `wire_zoff = WIRE_ZOFF + (sin(2k)·WIRE_ZOOM)>>7`. One object, no counter-
  rotating pair (the old cube+octahedron pair is replaced; `verts` = 12 vertices,
  `edges` = 30 pairs).
- **Draw**: hidden buffer only; D-only blit clear of the MID band; shared line-mode
  setup once per frame (`BLTCMOD = BLTDMOD = 40`, `BLTADAT = $8000`, `BLTBDAT = $FFFF`,
  `BLTAFWM = BLTALWM = $FFFF`); `BlitLine` per edge (octants table, SIGN rule
  `4·dmin − 2·dmaj < 0`, `BLTCON0 = (x1&15)<<12 | $0BCA`, `BLTSIZE = (dmaj+1)<<6|2`).
  **The blitter preload registers are written once in DrawWire before the edge
  loop and never reset** (fixes the emu test's "A data/B data/word masks not
  preloaded" precondition — the current code writes them inside DrawWire already;
  the refactor must keep them at those values across the whole frame and the test
  must verify them after the frame, not assume a prior state).
- The emu test's pixel-exact wireframe reference (`ref_wire`) is rewritten for the
  icosahedron: same math (7-bit matrix, perspective `round(WIRE_D·256/zc)`,
  Bresenham over the edge list read from the hunk symbols `verts`/`edges`/
  `edges_end`), so the check stays independent of the assembly.

### 2.4 Music engine (restructured `modplayer.s` + new tune)

- Keep the public API: `MOD_Init` (d0 = 1 ok / 0 bad), `MOD_Tick` (50 Hz, no return),
  `MOD_Stop`. Keep the Paula retrigger sequence and the silence-word one-shot handling.
- **Parse the MOD structurally, not by hardcoded offsets**: read the 31×30 instrument
  headers, compute pattern-data base = `980` (20 title + 930 instr + 26 order + 4
  "M.K." + 0 — the generator emits header + patterns + samples in that order, so
  patterns start at 980; the old `1084` assumed a 104-byte gap that does not exist —
  the generator's `bytes([4,0])` + 124 order bytes + `M.K.` is exactly 980 bytes, so
  `1084` was already wrong and only worked by luck of the sample-pointer walk; the
  refactor uses 980 and the validator asserts it).
  Wait — the generator writes: 20 title + 31×30 = 950 instr bytes (20+930=950) +
  songlen(1) + speed(1) + 128 order + 3 ("M.K.") = 1083? The current code reads the
  length at 950 and order at 952, and `M.K.` at 1080: 952 + 128 + 3 = 1083, so the
  header is 1083 bytes + the generator pads to 1084 (4-byte align) before patterns.
  The spec: **the generator pads the header to 1084 bytes; the player computes
  pattern base = 1084 by reading the "M.K." marker at offset 1080, not by a magic
  constant** (search forward from 952+128 for `M.K.`, the pattern base is the next
  4-aligned address). This removes the magic number without changing the file.
- **Sample pointer table: all 31 instruments** (the old loop ran 30; sample 31 was
  dead). Loop `31` iterations.
- **Effect coverage**: note+sample, sample default volume (clamp 64), `Cxx` volume,
  `F01..F1F` speed, **`A01..A0F` slide up**, **`A11..A1F` slide down**, `000` note cut
  handled implicitly by period 0. Everything else still falls through (the validator
  whitelists exactly what the player implements). Slide state is per-channel
  (`mod_slide[4]`, signed 16-bit, applied to AUDxFR every triggered row, cleared by
  note cut / row with no slide).
- **State layout** (data section, all in the chip block): `mod_sample_ptrs[31]`,
  `mod_loop_ptrs[4]`, `mod_loop_lens[4]`, `mod_slide[4]`, `mod_trigger_mask`,
  `mod_songlen`, `mod_order`, `mod_row`, `mod_tick`, `mod_speed`.
- **New tune** (`tools/generate_assets.py`, rewritten): 8 patterns × 64 rows, songlen
  8, order 0..7, one tempo `F10` (speed 16 → 125 BPM) on pattern 0 row 0 and `F06`…
  keep it simple: speed 6 (125 BPM), 4 tracks:
  - ch1 **bass**: square, 8th notes, root of each chord (Am–F–C–G twice, octave 1–2)
  - ch2 **lead**: sine arpeggio (16ths on beats 1 and 3), `A0x` slides on the top
    notes of the second bar of each 4-bar group (so the new effect is exercised)
  - ch3 **kick**: one-shot decayed sine sweep, every 8 rows
  - ch4 **hat**: one-shot seeded noise, off-beats (rows 2,6,10…); **new**: a ride-ish
    noise on rows 4,12,20… with `Cxx` volume automation on the 4th row of every 16
  31 instruments are filled (not 4): a second lead (detuned square for the second
  half of the song), a pad (low-volume saw-ish 256-byte loop), and spare noise
  variants — the tune uses instruments 1–8, the rest are valid empty/silence entries
  so the 31-instrument pointer table is fully populated. Samples stay unsigned
  (centred 128), deterministic (fixed seed), lengths ≤ 2048 bytes each so the chip
  block fits (chip budget: copper+screen+logo+font+sprites+mod ≤ 1024 KiB).
- The validator's MOD checks are updated to the new layout (M.K. at 1080, header
  1084, effect whitelist {0, 5, C, F}, F param 1..31, A param 1..15, period 113..856
  or 0).

### 2.5 Screen layout (rows, 256-tall, display line = row + 44)

| Rows | Region | Planes / mechanism |
|---|---|---|
| 0–7 | black | — |
| 8–71 | **logo** (wavy, BPLCON1 sine scroll, white→orange face gradient, animated bar at row 72) | planes 0–3, `cop_wave` 64 rows |
| 72–75 | gap; row 72 carries the animated COLOR00 slot (`cop_raster_color`) + wave reset | — |
| 76–195 | **middle band**: starfield + wireframe + sprite ball ring (double-buffered planes 1 & 3, BPLCON2 $0002 puts far balls behind) | `screen` p1/p3 buffers |
| 196–199 | gap | — |
| 200–215 | **scroller** (16 rows, MSB-first double-height font, ROXL shift) | plane 0 (+3) |
| 216–221 | gap | — |
| 222–255 | **copper-bar floor** (static ramp + 4 sine-driven bars, one WAIT per row, after the wrap) | `cop_bars` 34 rows |

Constants (EQU block in main.s, unchanged values unless noted): `SCREEN_W_BYTES 40`,
`SCREEN_H 256`, `PLANE_SIZE 10240`, `FRAME_SYNC_LINE 300`, `LOGO_Y 8 / LOGO_H 64`,
`MID_Y0 76 / MID_H 120`, `MID_CX 160 / MID_CY 136`, `SCROLL_Y 200 / SCROLL_H 16`,
`FLOOR_Y0 222 / FLOOR_H 34`, `NBARS 4`, `NSTARS 48`, `ZMIN 32 / ZRANGE 224 / ZSPEED 2 /
ZMID 150 / ZNEAR 80 / PROJ_F 128`, `WIRE_D 220 / WIRE_ZOFF 300`, `WIRE_SWAY 64 /
WIRE_ZOOM 18`, `NBALLS 8 / SPR_BYTES 80`, `RING_R 70 / RING_TILT 40`, `BALL_NEAR 285 /
BALL_MID 325`, `SILENCE_WORD $8080`. The new icosahedron replaces `CUBE_S/OCTA_S`.

## 3. Module contracts (per function: in/out registers, clobbers)

- `BeamLine` → d0 = line. Clobbers d0 only.
- `WaitFrameSync` → returns via RTS. No meaningful return.
- `WaitLines` d3.b = lines. Clobbers d0, d1.
- `ClearScreen` → zeroes all 6 planes. a0 = screen base set internally.
- `DrawLogo` → copies the 4 logo planes into the screen block (logo rows only).
- `InitStars`/`UpdateStars` → a0/a1 plane bases set internally (re-based); UpdateStars
  must NOT use adda/suba on a0/a1 (validator rule) and must index both `0(a0,d*.w)`
  and `0(a1,d*.w)`.
- `CalcMatrix` d0/d1/d2 = angles; writes `mat[9]` + globals `sx..cz`. Clobbers d0–d2, a2, a4.
- `TransformVerts` a1 = verts, d7 = count−1, d6 = magnitude, a3 = proj. Clobbers d0–d6, a2, a4, a5.
- `BlitLine` d0/d1 = (x1,y1), d2/d3 = (x2,y2), a0 = bitplane, a6 = CUSTOM. Clobbers d0–d7.
- `DrawWire` → no args. Clobbers everything (it is the last CPU drawing before the loop tail).
- `UpdateSprites`/`UpdateWave`/`UpdateBars`/`UpdateRaster`/`UpdateScroller` → no args.
- `MOD_Init` → d0 = 1/0. Clobbers d0–d7, a0–a4.
- `MOD_Tick`/`MOD_Stop` → no args. Clobber d0–d7, a0–a6.
- Every scene `Init_*` runs after `ClearScreen` and before `COP1LCH` is installed.

## 4. Data & chip layout

- `reloc_table` (12 longs, unchanged order): screen, logo_data, font_data,
  audio_silence, mod_data, copper, cop_bpl1, cop_raster_color, cop_wave, cop_bars,
  sprites, cop_spr.
- Chip block order (copper first so the emu test's `cop_bpl1 − copper` offset math
  works): copper list (incl. all palette/sprite/WAIT rows) → sprite pages (24 × 80) →
  left-fetch word → screen (6 × 10240) → logo_data → font_data → audio_silence → mod_data.
- `CHIPDATA_SIZE` is still `chipdata_end − chipdata_begin`.

## 5. Toolchain contract (what the tools must keep working on)

### 5.1 `tools/validate.py` — hooks (must all still pass, same intent)
Asset: logo.raw = 10240 B, font.raw = 760 B, MOD M.K. at 1080, header 1084,
songlen 1..128, size = 1084 + pats·1024 + Σ 2·len, sample vol ≤ 64, loop bounds,
period 0 or 113..856, effect whitelist {0, 5, C, F}.
Source: indexed-displacement −128..127 (EQU-resolved), no (pc) destination, no (pc)
data read outside lea/pea/jsr/jmp/bsr, no ADDI-class to aR, quick counts 1..8, no
writes to DMACONR/INTENAR/INTREQR/ADKCONR/VPOSR/VHPOSR, no `bsr.s`/`bra.s`/short-
cond `.s`, symbol cross-reference across hardware.i + main.s + all included .s
files (the validator's source list must include the new scene files), duplicate
globals, local-label scope, `chipdata,data_c` section with the 6 chipdata labels in
it, chipdata-label discipline (only in definition line or `dc.l` reloc lines),
copper span `copper:`..`screen:` ends [0xFFFF,0xFFFE], even words, WAIT bit-0 rule,
MOVE reg 0x20..0x1FE, standard words present (DIWSTRT $2C81, DIWSTOP $2CC1, DDFSTRT
$0030, DDFSTOP $00D0, BPLCON0 $4200, BPL1MOD/BPL2MOD $FFFE), COLOR00 written ≥ 1,
`cop_raster_color:` is a COLOR00 pair, `cop_bpl1` reg sequence E0..EE, PatchCopper
writes offsets 2,6,10,14,18,22 and never 0,4,8,12,16,20, COP1LCH+COPJMP1 present,
UpdateStars contract, code/data sections exist and every code label ends in rts,
_start Forbid-before-Disable + 4.w-before-jsr, teardown Enable-before-Permit +
MOD_Stop-before-LoadView + $7FFF INTENA/INTREQ, hardware.i EQUs exact (DMAF_*, MEMF_*,
LVO_*, GfxBase_*), AllocChipMem TypeOfMem+MEMF_CHIP+FreeMem, SILENCE_WORD $8080,
every `jsr LVO_xxx(aN)` uses a6, Exec-arg window check (≥ 14 calls), audio sample
sanity (mean 96..160, LEAD/KICK max-step ≤ 64, HAT decays), logo ink bounds,
font non-blank glyphs.

### 5.2 `tools/emu_test.py` — hooks (symbols the test looks up by hunk name)
`WaitFrameSync`, `UpdateSprites`, `UpdateStars`, `UpdateScroller`, `DrawWire`
(frame marks + beam-slack), `cop_bpl1`, `copper`, `scroll_ptr`, `scroll_text`,
`glyph_col`, `verts`, `edges`, `edges_end`, `reloc_table` (+0 screen, +12 silence,
+16 mod, +40 sprites). EQUs read from source: `WIRE_D, WIRE_ZOFF, MID_CX, MID_CY,
WIRE_SWAY, WIRE_ZOOM, LOGO_Y, LOGO_H, MID_Y0, MID_H, SCROLL_Y, NSTARS, ZMIN, ZRANGE,
ZSPEED, ZMID, ZNEAR, PROJ_F, RING_R, RING_TILT, BALL_NEAR, BALL_MID, SPR_BYTES,
FRAME_SYNC_LINE`. The wireframe reference (`ref_wire`) is rewritten for the
icosahedron; the audio reference is rewritten for the new 8-pattern tune + slides;
the machine68k API is pinned to **0.3.0** (the harness is ported: `execute()` returns
int cycles, no `w16s_reg` — 16-bit register state is read as `r_reg` + mask, 16-bit
custom-register access already goes through `mem.w16/r16`, and the `Register` enum is
used for d/a registers). The blitter line-mode model keeps requiring the preloaded
`BLTDATAA = $8000`, `BLTDATAD = $FFFF`, `BLTAFWM = BLTALWM = $FFFF` (now written once
per frame by DrawWire, so the precondition holds).

### 5.3 `tools/gen_tables.py` — subcommands kept: `copper, sintab, recip_star,
recip_wire, floor_base, bar_colors, wave_tab, palette, balls, spr_palette,
ring_tab`. New: `icosahedron` (prints the `verts`/`edges` tables) — or the tables
are hand-written in main.s and gen_tables prints nothing for them; the spec chooses:
**the icosahedron tables are generated** (`gen_tables.py ico`) and pasted, so the
emu reference and the assembly come from one source. `MID_PALETTE`, `NBARS`,
`FLOOR_Y0`, `FLOOR_H`, `wave_tab()`, `floor_base()`, `bar_colors()`, `ball_lines()`,
`spr_palette_regs()` stay importable by emu_test.

### 5.4 `tools/generate_assets.py` — outputs: `logo.raw` (via logo_art, unchanged),
`font.raw` (unchanged), `logo_preview.png` (unchanged), `neon.mod` (new tune per
§2.4). Deterministic, stdlib only. `make verify-repro` must stay green.

### 5.5 Mutation harnesses
`tools/mutate.py` and `tools/mutate_emu.py` are rewritten for the new sources: same
shape `(name, file, old, new, expect)`, each old-string must exist verbatim in the
new code, each mutant must be caught. The 33+25 intent list is ported 1:1 where the
code it targets survived (Forbid/Disable order, a6 base, chipdata discipline,
Copper words, relocation, Paula LEN, octant table, buffer swap, wave step, …) and
re-anchored on the new files where it moved.

## 6. CPU budget & verification

- Target: < 77 000 average / < 84 000 worst cycles per frame (the emu test enforces
  worst < 85 % of 142 000). The icosahedron (30 edges) costs more than the old
  24-edge pair; if the budget is broken, the first lever is star count (48 → 40),
  the second is the blitter edge setup frequency (never per-edge register spam).
- Definition of done: `make` (assets if stale → validate → assemble → hunkcheck),
  `make validate`, `make mutants`, `make emutest`, `make verify-repro` all green;
  `make emu-mutants` green if the 25 emu mutants are ported (they are).
- `docs/GFX.md`, `docs/MUSIC.md`, `docs/ARCHITECTURE.md`, `README.md` updated to
  describe the icosahedron, the scene modules, the 8-pattern tune with slides, and
  the dropped Phase-2/3/4 machinery.
