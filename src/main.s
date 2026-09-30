        include "hardware.i"

SCREEN_W_BYTES  EQU 40
SCREEN_H        EQU 256
PLANE_SIZE      EQU SCREEN_W_BYTES*SCREEN_H
PLANE_LONGS     EQU PLANE_SIZE/4
SCROLL_Y        EQU 210
SCROLL_H        EQU 16
CHIPDATA_SIZE   EQU chipdata_end-chipdata_begin
LOGO_Y          EQU 48
LOGO_H          EQU 64
FRAME_SYNC_LINE EQU 300     ; first line below the display window (DIWSTOP = line 300)
SILENCE_WORD    EQU $8080   ; 8 bit Paula silence is unsigned $80, not 0

; Runtime pointer slots. AllocChipMem copies the whole data_c block into chip
; RAM and rewrites every one of these long words to point into the copy, so no
; code may use a chipdata label as an address directly.
ptr_screen   equ reloc_table+0
ptr_logo     equ reloc_table+4
ptr_font     equ reloc_table+8
ptr_silence  equ reloc_table+12
ptr_mod      equ reloc_table+16
ptr_copper   equ reloc_table+20
ptr_cop_bpl1 equ reloc_table+24
ptr_raster   equ reloc_table+28

        section code,code
        xdef    _start
_start:
        movem.l d0-d7/a0-a6,-(sp)

; --- capture the system display state ---------------------------------------
; COP1LC is a write side custom register and cannot be read back, so the
; documented system startup list pointer is taken from GfxBase->copinit.
; All data below is addressed absolutely: the hunk loader relocates it, whereas
; PC-relative addressing cannot reach another hunk and cannot be a destination.
        move.l  4.w,a5
        lea     gfx_name,a1                 ; OldOpenLibrary(a1 = name, d0 = version)
        moveq   #0,d0
        jsr     LVO_OldOpenLibrary(a5)
        move.l  d0,gfx_base
        beq     .open_fail
        move.l  d0,a0
        move.l  GfxBase_ActiView(a0),old_view
        move.l  GfxBase_copinit(a0),old_copper

; --- move every DMA visible payload into chip RAM ---------------------------
; Done while interrupts are still enabled: AllocMem must not be called from a
; Forbid/Disable section. The copy makes the demo work even if the loader
; ignored the data_c chip memory flag.
        bsr     AllocChipMem
        tst.l   d0
        beq     .alloc_fail

; --- detach the system view before touching the chipset --------------------
; Still with interrupts enabled, because WaitTOF() relies on the vertical
; blank interrupt owned by graphics.library.
        move.l  gfx_base,a6
        sub.l   a1,a1                      ; LoadView(a1 = NULL) detaches the View
        jsr     LVO_LoadView(a6)
        jsr     LVO_WaitTOF(a6)
        jsr     LVO_WaitTOF(a6)
        jsr     LVO_OwnBlitter(a6)
        jsr     LVO_WaitBlit(a6)

; --- snapshot the registers this demo overwrites ---------------------------
        lea     CUSTOM,a6
        move.w  DMACONR(a6),old_dmacon
        move.w  INTENAR(a6),old_intena
        move.w  ADKCONR(a6),old_adkcon

; --- take the chipset away from the operating system -----------------------
; Forbid() first, so no task switch can happen between Forbid and Disable.
        move.l  4.w,a5
        jsr     LVO_Forbid(a5)
        jsr     LVO_Disable(a5)

        move.w  #$7FFF,INTENA(a6)          ; clear every interrupt enable
        move.w  #$7FFF,INTREQ(a6)          ; acknowledge every interrupt
        move.w  #DMAF_ALL,DMACON(a6)       ; stop all DMA
        move.w  #$7FFF,ADKCON(a6)          ; clear every ADKCON bit: no UART/disk mods

        bsr     ClearScreen
        bsr     DrawLogo
        bsr     InitStars
        bsr     PatchCopper
        bsr     MOD_Init

        move.l  ptr_copper,d0
        move.l  d0,COP1LCH(a6)
        move.w  #0,COPJMP1(a6)
; Audio DMA stays off here: a channel enabled before MOD_Row has loaded its
; location and length would play 128 KB of arbitrary memory as noise. Each
; channel is switched on by its first note.
        move.w  #(DMAF_SETCLR|DMAF_MASTER|DMAF_RASTER|DMAF_COPPER),DMACON(a6)

; --- main loop --------------------------------------------------------------
; One iteration per PAL frame: WaitFrameSync returns as the beam leaves the
; display window, so everything drawn below lands in the frame shown next.
.main:
        bsr     WaitFrameSync
        bsr     MOD_Tick
        bsr     UpdateRaster
        bsr     UpdateStars
        bsr     UpdateScroller
        btst    #6,CIAAPRA                 ; left mouse button, active low
        bne     .main

; --- teardown ---------------------------------------------------------------
; Stop the demo first, then hand the View back, then the Copper: LoadView only
; installs the View, it does not restart the system Copper list.
        bsr     MOD_Stop
        lea     CUSTOM,a6
        move.w  #$7FFF,INTENA(a6)
        move.w  #$7FFF,INTREQ(a6)
        move.w  #DMAF_ALL,DMACON(a6)

        move.l  gfx_base,a6
        move.l  old_view,a1                ; LoadView(a1 = View)
        jsr     LVO_LoadView(a6)

        lea     CUSTOM,a6
        move.l  old_copper,d0
        move.l  d0,COP1LCH(a6)
        move.w  #0,COPJMP1(a6)

        move.l  4.w,a5
        jsr     LVO_Enable(a5)             ; interrupts before any wait
        jsr     LVO_Permit(a5)

        move.l  gfx_base,a6
        jsr     LVO_WaitTOF(a6)
        jsr     LVO_WaitTOF(a6)
        jsr     LVO_DisownBlitter(a6)

; Restore the saved register values as SET/CLR writes, which is the only way
; to write the read-side DMACONR/INTENAR/ADKCONR state back. Audio DMA is
; deliberately left off: Paula location/length state is not snapshottable.
; BPLCON0/1/2 and the modulos are not restored by hand: LoadView and the
; restarted system Copper list rewrite them on the next frame.
        lea     CUSTOM,a6
        move.w  old_adkcon,d0
        andi.w  #$7FFF,d0
        ori.w   #$8000,d0
        move.w  d0,ADKCON(a6)
        move.w  old_intena,d0
        andi.w  #$7FFF,d0
        ori.w   #$8000,d0
        move.w  d0,INTENA(a6)
        move.w  old_dmacon,d0
        andi.w  #DMAF_SYSTEM,d0            ; everything except audio 0-3
        ori.w   #$8000,d0
        move.w  d0,DMACON(a6)

; The hardware no longer reads the payload block, so it can be returned.
        move.l  4.w,a5
        move.l  chip_base,a1               ; FreeMem(a1 = block, d0 = size)
        move.l  #CHIPDATA_SIZE,d0
        jsr     LVO_FreeMem(a5)

        move.l  gfx_base,a1                ; CloseLibrary(a1 = library)
        jsr     LVO_CloseLibrary(a5)
        movem.l (sp)+,d0-d7/a0-a6
        moveq   #RETURN_OK,d0
        rts

.open_fail:
        movem.l (sp)+,d0-d7/a0-a6
        moveq   #RETURN_FAIL,d0
        rts

.alloc_fail:
        move.l  4.w,a5
        move.l  gfx_base,a1
        jsr     LVO_CloseLibrary(a5)
        movem.l (sp)+,d0-d7/a0-a6
        moveq   #RETURN_FAIL,d0
        rts

; ---------------------------------------------------------------------------
; Chip memory. The data_c block is one contiguous run, so it is copied as a
; whole and every label inside it is re-based in one pass.
; ---------------------------------------------------------------------------
AllocChipMem:
        move.l  4.w,a5
        move.l  #CHIPDATA_SIZE,d0          ; AllocMem(d0 = size, d1 = flags)
        move.l  #MEMF_CHIP,d1
        jsr     LVO_AllocMem(a5)
        move.l  d0,chip_base
        beq     .no_mem

; Confirm what the allocator returned instead of assuming it: bitplane, Copper
; and Paula DMA cannot be pointed at fast RAM, so a non chip block is a failure
; and the memory is handed straight back.
        move.l  d0,a1                      ; TypeOfMem(a1 = address)
        jsr     LVO_TypeOfMem(a5)
        andi.l  #MEMF_CHIP,d0
        bne     .have_mem
        move.l  chip_base,a1               ; FreeMem(a1 = block, d0 = size)
        move.l  #CHIPDATA_SIZE,d0
        jsr     LVO_FreeMem(a5)
        clr.l   chip_base
        bra     .no_mem
.have_mem:

; Copy the assembled payload block into the allocated memory with Exec's
; CopyMem(a0 = source, a1 = dest, d0 = size).
        lea     chipdata_begin,a0
        move.l  chip_base,a1
        move.l  #CHIPDATA_SIZE,d0
        jsr     LVO_CopyMem(a5)

; Re-base every long in reloc_table: runtime = base + (assembled - block).
        lea     chipdata_begin,a6
        move.l  chip_base,a5
        lea     reloc_table,a4
        move.w  #RELOC_COUNT-1,d6
.reloc:
        move.l  (a4),d0
        sub.l   a6,d0
        add.l   a5,d0
        move.l  d0,(a4)+
        dbra    d6,.reloc

        move.l  chip_base,d0
        rts
.no_mem:
        moveq   #0,d0
        rts

; ---------------------------------------------------------------------------
; Beam position helpers.
;
; VPOSR and VHPOSR are adjacent, so one long read returns both in a single bus
; access and cannot straddle a line change. VPOSR bit0 is V8 (long bit 16) and
; VHPOSR bits 15-8 are V7..V0, so after a shift by eight the low nine bits are
; the PAL line number. a6 must be CUSTOM. Only d0 is clobbered.
; ---------------------------------------------------------------------------
BeamLine:
        move.l  VPOSR(a6),d0
        lsr.l   #8,d0
        andi.w  #$01FF,d0
        rts

; Sync to the first line below the display window, once per frame. The loop
; first leaves the sync zone, so a frame whose work finished below the sync
; line is not counted twice: one call per frame gives the tracker tick rate of
; 50 Hz on both the 312 and the 313 line PAL frame.
;
; The intro is PAL only. On a 262 line NTSC frame line 300 never arrives, which
; would hang a machine that has interrupts disabled, so the wait also ends when
; the beam wraps to the top of the frame (the intro then runs, badly timed,
; instead of locking up, and the mouse button still exits).
WaitFrameSync:
.leave:
        bsr     BeamLine
        cmp.w   #FRAME_SYNC_LINE,d0
        bhs     .leave
.enter:
        move.w  d0,d2                      ; previous line
        bsr     BeamLine
        cmp.w   #FRAME_SYNC_LINE,d0
        bhs     .synced
        cmp.w   d2,d0
        bhs     .enter                     ; still counting up
.synced:
        rts

; Wait for d3.b raster lines to pass. a6 must be CUSTOM.
WaitLines:
.w1:
        bsr     BeamLine
        move.w  d0,d1
.w2:
        bsr     BeamLine
        cmp.w   d1,d0
        beq     .w2
        subq.b  #1,d3
        bne     .w1
        rts

; ---------------------------------------------------------------------------
; Screen setup.
; ---------------------------------------------------------------------------
ClearScreen:
        move.l  ptr_screen,a0
        moveq   #0,d0
        move.w  #PLANE_LONGS*3-1,d7
.cs:
        move.l  d0,(a0)+
        dbra    d7,.cs
        rts

DrawLogo:
        move.l  ptr_logo,a0
        move.l  ptr_screen,a1
        adda.l  #LOGO_Y*SCREEN_W_BYTES,a1
        move.w  #(SCREEN_W_BYTES*LOGO_H/4)-1,d7
.dl:
        move.l  (a0)+,(a1)+
        dbra    d7,.dl
        rts

; Rewrite the three bitplane pointer pairs in the copied Copper list. The list is
; stored as MOVE pairs, so the register words sit at byte offsets 0/4/8/12/16/20
; and the data words that PatchCopper overwrites at 2/6, 10/14 and 18/22.
PatchCopper:
        move.l  ptr_cop_bpl1,a1
        move.l  ptr_screen,d0
        move.l  d0,d3
        move.w  d0,6(a1)                   ; BPL1PTL
        swap    d0
        move.w  d0,2(a1)                   ; BPL1PTH
        move.l  d3,d0
        addi.l  #PLANE_SIZE,d0
        move.w  d0,14(a1)                  ; BPL2PTL
        swap    d0
        move.w  d0,10(a1)                  ; BPL2PTH
        move.l  d3,d0
        addi.l  #PLANE_SIZE*2,d0
        move.w  d0,22(a1)                  ; BPL3PTL
        swap    d0
        move.w  d0,18(a1)                  ; BPL3PTH
        rts

; ---------------------------------------------------------------------------
; Animated Copper colour slot. This is the COLOR00 pair at raster line $80, so
; the CPU animated band and the Copper side of the list cannot fight: the
; update happens below the display window, the Copper reads the slot at line 128.
; ---------------------------------------------------------------------------
UpdateRaster:
        addq.w  #1,phase
        move.w  phase,d0
        andi.w  #$1F,d0
        lea     raster_colors,a0
        add.w   d0,d0
        move.w  0(a0,d0.w),d1
        move.l  ptr_raster,a1
        move.w  d1,2(a1)
        rts

; ---------------------------------------------------------------------------
; Stars. Each entry is the x coordinate and the byte offset of its fixed row
; (y * 40); the byte within the row follows x, so a star drifts across the
; screen one pixel per frame.
; ---------------------------------------------------------------------------
InitStars:
        lea     stars,a0
        moveq   #0,d0
        moveq   #31,d7
.is:
        move.w  d0,(a0)+                   ; x
        move.w  d0,d1
        mulu    #37,d1
        andi.w  #63,d1
        addi.w  #128,d1                    ; y = 128..191
        mulu    #SCREEN_W_BYTES,d1         ; byte offset of the start of line y
        move.w  d1,(a0)+                   ; row offset; StarAddress adds x/8
        add.w   #73,d0
        cmp.w   #320,d0
        blo     .isok
        subi.w  #320,d0
.isok:
        dbra    d7,.is
        rts

; Erase every star at its current x, then advance and draw them: two stars that
; share a byte and a bit in the same frame must not cancel each other out. The
; stored x is always the x that was drawn, so the next frame erases exactly that
; pixel. The bit mask is built with data register shifts and applied with a
; read/modify/write through a data register.
UpdateStars:
        move.l  ptr_screen,a0
        adda.l  #PLANE_SIZE*2,a0           ; plane 2
        lea     stars,a1
        moveq   #31,d7
.us_er:
        bsr     StarAddress
        move.b  (a2),d3
        not.b   d1
        and.b   d1,d3
        move.b  d3,(a2)
        addq.l  #4,a1
        dbra    d7,.us_er

        lea     stars,a1
        moveq   #31,d7
.us_dr:
        move.w  (a1),d0
        addq.w  #1,d0
        cmp.w   #320,d0
        blo     .xok
        clr.w   d0
.xok:
        move.w  d0,(a1)                    ; store the new x before it is drawn
        bsr     StarAddress
        move.b  (a2),d3
        or.b    d1,d3
        move.b  d3,(a2)
        addq.l  #4,a1
        dbra    d7,.us_dr
        rts

; in: a0 = plane base, a1 points at one star entry;
; out: a2 = the star byte, d1 = its bit mask. a0 must survive: the caller loops
; over all 32 stars with one base, so the offset is addressed instead of added
; to a0, which would walk a0 off the end of the bitplane.
StarAddress:
        move.w  (a1),d3
        move.w  d3,d2
        lsr.w   #3,d2                      ; x / 8
        add.w   2(a1),d2                   ; + row offset
        lea     0(a0,d2.w),a2
        andi.w  #7,d3
        moveq   #7,d1
        sub.w   d3,d1                      ; bit number, MSB first
        moveq   #1,d0
        lsl.w   d1,d0
        move.w  d0,d1
        rts

; ---------------------------------------------------------------------------
; Scroller. Every update shifts the sixteen scroller rows one pixel left. A row
; is 40 bytes, so it is shifted as ten big endian longwords with ROXL, from the
; rightmost longword to the leftmost: each longword's bit 31 falls into X and
; enters the next longword to its left at bit 0. Rows and planes are 4-byte
; aligned, so the long accesses are legal on a 68000. Longwords roughly halve
; the cost of a word loop, which keeps the whole frame inside the vblank window.
;
; MOVEQ does not touch X, so X is cleared explicitly before each row; MOVE,
; SUBQ on an address register and DBRA all leave X alone between two shifts.
; ---------------------------------------------------------------------------
UpdateScroller:
        addq.b  #1,scroll_div
        cmp.b   #2,scroll_div
        blo     .done
        clr.b   scroll_div

        move.l  ptr_screen,a0
        adda.l  #PLANE_SIZE+(SCROLL_Y*SCREEN_W_BYTES),a0
        moveq   #SCROLL_H-1,d7
.sc_row:
        lea     SCREEN_W_BYTES-4(a0),a4    ; last longword of the row
        moveq   #SCREEN_W_BYTES/4-1,d6
        andi    #$EF,ccr                   ; X = 0 enters the rightmost longword
.sc_long:
        move.l  (a4),d1
        roxl.l  #1,d1
        move.l  d1,(a4)
        subq.l  #4,a4
        dbra    d6,.sc_long
        lea     SCREEN_W_BYTES(a0),a0
        dbra    d7,.sc_row

        addq.b  #1,glyph_col
        cmp.b   #8,glyph_col
        blo     .sc_insert
        clr.b   glyph_col
        addq.l  #1,scroll_ptr
        move.l  scroll_ptr,a1
        tst.b   (a1)
        bne     .sc_insert
        lea     scroll_text,a1
        move.l  a1,scroll_ptr
.sc_insert:
        move.l  scroll_ptr,a1
        moveq   #0,d0
        move.b  (a1),d0
        sub.w   #32,d0
        bpl     .sc_chr_ok
        moveq   #0,d0                     ; below the font, render a blank
.sc_chr_ok:
        cmp.w   #95,d0
        blo     .sc_chr_range
        moveq   #0,d0                     ; above the font, render a blank
.sc_chr_range:
        lsl.w   #3,d0
        move.l  ptr_font,a2
        adda.l  d0,a2
        moveq   #0,d1
        move.b  glyph_col,d1
        moveq   #7,d2
        sub.w   d1,d2                      ; bit of this column inside the byte
        move.l  ptr_screen,a0
        adda.l  #PLANE_SIZE+(SCROLL_Y*SCREEN_W_BYTES)+SCREEN_W_BYTES-1,a0
        moveq   #7,d7
.sc_glyph:                                 ; every font row is drawn on two lines
        move.b  (a2)+,d3
        btst    d2,d3
        beq     .sc_zero
        bset    #0,(a0)
        bset    #0,SCREEN_W_BYTES(a0)
        bra     .sc_next
.sc_zero:
        bclr    #0,(a0)
        bclr    #0,SCREEN_W_BYTES(a0)
.sc_next:
        lea     SCREEN_W_BYTES*2(a0),a0
        dbra    d7,.sc_glyph
.done:
        rts

        include "modplayer.s"

        section data,data
old_dmacon:  dc.w 0
old_intena:  dc.w 0
old_adkcon:  dc.w 0
phase:       dc.w 0
scroll_div:  dc.b 0
glyph_col:   dc.b 0
        even
old_copper:  dc.l 0
old_view:    dc.l 0
gfx_base:    dc.l 0
chip_base:   dc.l 0
scroll_ptr:  dc.l scroll_text
stars:       ds.w 64            ; 32 * (x, byte offset)

; The eight DMA visible labels as link-time addresses. AllocChipMem rewrites
; every long word in place, so ptr_* slots hold runtime chip RAM addresses.
        even
reloc_table:
        dc.l screen,logo_data,font_data,audio_silence,mod_data,copper,cop_bpl1,cop_raster_color
RELOC_COUNT     EQU 8

gfx_name:    dc.b "graphics.library",0
        even

scroll_text:
        dc.b "   NEON VECTORS PRESENTS: A TINY 68000 / OCS CRACKTRO - COPPER RASTERS - PAULA MOD - PLANAR GFX - GREETINGS TO EVERYONE STILL MAKING THE OLD MACHINES SING!   ",0
        even

raster_colors:
        dc.w $102,$203,$304,$405,$506,$607,$708,$819
        dc.w $92A,$A3B,$B4C,$C5D,$D6E,$E7F,$D6E,$C5D
        dc.w $B4C,$A3B,$92A,$819,$708,$607,$506,$405
        dc.w $304,$203,$102,$213,$324,$435,$546,$657

; ---------------------------------------------------------------------------
; All DMA visible payloads. The block is copied into freshly allocated chip
; RAM at run time, so the loader may place it anywhere without breaking the
; Copper, the bitplanes, the Paula samples or the silent terminal word.
;
; Copper WAIT is a two word instruction: word one is the beam position with
; bit0 set, word two is the comparison mask with bit0 clear and bit15 set for
; blitter finished. $xx01,$FFFE therefore waits for vertical position $xx with
; every vertical and horizontal bit compared, and $FFFF,$FFFE never matches,
; which parks the list until the next vertical blank reloads COP1LC.
; ---------------------------------------------------------------------------
        section chipdata,data_c
        cnop 0,4
chipdata_begin:
copper:
        dc.w DIWSTRT,$2C81,DIWSTOP,$2CC1
        dc.w DDFSTRT,$0038,DDFSTOP,$00D0
        dc.w BPLCON0,$3200,BPLCON1,$0000,BPLCON2,$0000
        dc.w BPL1MOD,$0000,BPL2MOD,$0000
cop_bpl1:
        dc.w BPL1PTH,0,BPL1PTL,0
        dc.w BPL2PTH,0,BPL2PTL,0
        dc.w BPL3PTH,0,BPL3PTL,0
        dc.w COLOR00,$001,$0182,$FFF,$0184,$5DF,$0186,$27A
        dc.w $0188,$8BF,$018A,$248,$018C,$48C,$018E,$8CF
        dc.w $8001,$FFFE
cop_raster_color:
        dc.w COLOR00,$013            ; animated by UpdateRaster each frame
        dc.w $8801,$FFFE,COLOR00,$024
        dc.w $9001,$FFFE,COLOR00,$035
        dc.w $9801,$FFFE,COLOR00,$046
        dc.w $A001,$FFFE,COLOR00,$057
        dc.w $A801,$FFFE,COLOR00,$001
        dc.w $FFFF,$FFFE

        cnop 0,4
screen:     ds.b PLANE_SIZE*3
logo_data:  incbin "assets/logo.raw"
font_data:  incbin "assets/font.raw"
        even
audio_silence: dc.w SILENCE_WORD  ; unsigned 8 bit silence, not 0
mod_data:   incbin "assets/neon.mod"
        even
chipdata_end:
