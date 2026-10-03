# Music / Paula

`assets/neon.mod` is a deterministic four-channel, 31-instrument `M.K.` ProTracker
module with 8 patterns × 64 rows, produced by `tools/generate_assets.py`.

Channels:
- **ch1 bass**: square wave, 8th notes, root of each chord (Am–F–C–G, twice)
- **ch2 lead**: sine arpeggio (16ths on beats 1 and 3), `A0x` slide-up on the top
  notes of the second bar of each 4-bar group
- **ch3 kick**: one-shot decayed sine sweep, every 8 rows
- **ch4 hat**: one-shot seeded noise, off-beats (rows 2, 6, 10, …)

All 31 instrument slots are populated: instruments 1–8 carry the musical content
(bass, lead, detuned lead, pad, kick, hat, ride noise, spare noise), instruments 9–31
are valid silence entries (1-word `$80` sample, length 1, loop 1). The 31-instrument
pointer table in the player is fully populated.

All sample data is **unsigned and centred on 128**: Paula plays 8-bit samples as
unsigned bytes. Signed data masked with `&255` would sit near full scale and click at
every loop point. The hi-hat decays exponentially. The validator asserts both
properties (mean 96–160 for non-silence samples, max step ≤ 64 for LEAD/KICK, HAT
rms decay).

## MOD structure

```
offset  size  content
0       20    title ("NEON VECTORS" padded)
20      930   31 × 30-byte instrument headers (22 name + 2 length + 1 type + 1 volume + 2 loop-start + 2 loop-length)
950     1     song length (8)
951     1     speed (6)
952     128   order list (0..7, rest 255)
1080    4     "M.K." signature
1084    8192  8 patterns × 1024 bytes (64 rows × 4 channels × 4 bytes)
9276    2356  sample data (256 + 256 + 1024 + 512 + 256 + 26 × 2 = 2356 bytes)
          ----
          11632 bytes total
```

The player finds the pattern base by searching for the `"M.K."` marker at offset 1080
and taking the next 4-aligned address (1084), rather than using a magic constant.

## Timing

At PAL 50 Hz and ProTracker speed 6, one vertical blank is one tracker tick; six ticks
give one row. 8 patterns × 64 rows = 512 rows = 3072 ticks = 61.44 seconds of music.
`tools/emu_test.py` verifies that rows start on ticks that are multiples of six frames
apart.

## Retrigger sequence

For every row, for each channel that has a sample and a period:

1. Set the channel's volume (sample default, or `Cxx`).
2. Clear that channel's DMACON bit, then write location, **length in words**, and
   period. (`AUDxLEN` is the word count, not count − 1; 0 would mean 65 536 words, so
   a zero-length sample is written as 1.)
3. Cache the loop location/length — or, for a one-shot, the silence word with length 1.

When all channels have been prepared, two raster lines are waited, the triggered
channels are re-enabled in one DMACON write (Paula latches location and length at that
moment), two more lines are waited, and then the cached loop/terminal location and
length are written for the next pass.

Audio DMA is enabled only by this sequence — never at startup — so no channel runs
without a valid sample.

The channel registers are addressed through `a1 = CUSTOM + AUD0LCH + channel*16` and
the offsets `0/4/6/8(a1)` (location, length, period, volume): the register numbers
themselves are too large for the 8-bit displacement of an indexed addressing mode.

## Supported effects

| Effect | Meaning | Implementation |
|---|---|---|
| Note + sample | Play note on this channel | Standard: set period, trigger |
| Period 0 | Note cut | Silence the channel |
| `A01..A0F` | Slide up (period decreases) | Per-channel `mod_slide[4]` state, applied to AUDxFR each row |
| `Cxx` | Set volume | 0–64, clamped |
| `F01..F1F` | Set speed (ticks per row) | 1–31 |

The validator whitelists exactly these effects (effect codes 0, A, C, F; `A` param
0x01–0x0F for slide-up only; `F` param 1–31). Any other effect — including `A1x`
slide-down, `F20+` BPM mode, `Dxx` vibrato, `Exx` fine tune — is rejected rather than
mis-played.

## Slide state

`mod_slide[4]` holds the per-channel slide amount (signed 16-bit, typically 1–15).
Each triggered row with an `A0x` effect sets the slide; subsequent rows with no effect
but the same note continue the slide (the period is adjusted each row). A note cut
(period 0) or a row with no slide clears the state. The slide is applied by
subtracting the slide amount from the current period each row (clamped at the
minimum period 113).

## State layout

All in the data hunk (not chip RAM — the MOD file is in the chip block, but the
player's working state is in the ordinary data hunk):

| Symbol | Size | Purpose |
|---|---|---|
| `mod_sample_ptrs[31]` | 124 bytes | Re-based chip RAM address of each instrument's sample data |
| `mod_loop_ptrs[4]` | 16 bytes | Per-channel cached loop/terminal location |
| `mod_loop_lens[4]` | 8 bytes | Per-channel cached loop/terminal length |
| `mod_slide[4]` | 8 bytes | Per-channel slide amount |
| `mod_trigger_mask` | 2 bytes | Which channels are triggered this row |
| `mod_songlen` | 1 byte | Number of patterns in the order list |
| `mod_order` | 1 byte | Current pattern index |
| `mod_row` | 1 byte | Current row within the pattern (0–63) |
| `mod_tick` | 1 byte | Tick counter (0–speed−1) |
| `mod_speed` | 1 byte | Ticks per row (set by `F01..F1F`) |
| `mod_pattern_base` | 4 bytes | Chip RAM address of pattern data |

## Verification

The emulation test checks, for every trigger, the channel, sample start inside the
module, length, period and volume against the module data, the slide amount and its
application across consecutive rows, and the loop/terminal registers loaded
afterwards.
