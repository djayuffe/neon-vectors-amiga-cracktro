# Release notes

## Audit revision

Full audit of the code, tooling and documentation; see [`docs/AUDIT.md`](docs/AUDIT.md) for the
complete list (32 defects).

**The program now assembles and runs.** The previous revision could not be assembled: it
contained PC-relative destinations, out-of-range indexed displacements, invalid immediates and
address-register forms of `addi`. Behind those were functional bugs that would have stopped it
working even once it assembled.

Highlights:

- Correct `DMACON` bit positions (the old values would never have enabled the Copper).
- Correct Exec/graphics.library register conventions and vector offsets (`a1` for names, libraries
  and blocks; `CopyMem` source/dest order and `-624`); library base in `a6` (AROS crashed on `a5`);
  `OpenLibrary` instead of the obsolete `OldOpenLibrary`.
- Teardown no longer hangs: the vertical-blank interrupt is re-enabled before `WaitTOF`.
- Relocation table loop and base address fixed; chip memory freed on exit.
- Audio: no noise burst at start (audio DMA was enabled with no sample), correct `AUDxLEN`, working
  2-line waits (`BeamLine` no longer clobbers `d1`).
- Frame loop synchronises once per frame (edge detection); no lock-up on a 262-line frame.
- Scroller shifts the right number of longwords, clears X explicitly, draws double-height text and
  fits the vblank window; stars actually move across the screen and leave no trails and are visible.
- `hunkcheck.py` memory flags fixed; `validate.py` corrected and extended; `mutate.py` now 32
  faults; wrong claims in the docs removed.
- New `tools/emu_test.py` and `make emutest`: the real binary is executed on an emulated 68000.
- New README, `docs/AUDIT.md`, `.gitignore`, `docs/screenshot.png`.

Status: host checks, the mutation self-test and the emulated-CPU test pass, and the program runs and
exits cleanly in FS-UAE (A500, AROS ROM). Not yet verified with a genuine Kickstart ROM or on real
hardware (checklist in `docs/BUILD_AND_TEST.md`).

## Earlier revisions

Earlier revisions (per-project history before this repository) introduced the generated assets,
the validator, the reproducibility check, the VASM bootstrap and the Hunk parser. Their changelog
entries claimed fixes that were not in the code or were wrong; those claims have been dropped.
