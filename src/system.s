; ---------------------------------------------------------------------------
; System takeover, chip memory, frame sync, restore. This file is included
; from main.s; the scene modules are spliced in below _start's helpers so
; that every bsr target is defined before its first call site (VASM 1.8f
; kick1hunks is single-pass).
; ---------------------------------------------------------------------------

        section code,code

; --- helper functions (must precede _start for VASM single-pass bsr) -------

; Chip memory. The data_c block is one contiguous run, so it is copied as a
; whole and every label inside it is re-based in one pass.
AllocChipMem:
        move.l  4.w,a6
        move.l  #CHIPDATA_SIZE,d0          ; AllocMem(d0 = size, d1 = flags)
        move.l  #MEMF_CHIP,d1
        jsr     LVO_AllocMem(a6)
        move.l  d0,chip_base
        beq     .no_mem

; Confirm what the allocator returned instead of assuming it: bitplane, Copper
; and Paula DMA cannot be pointed at fast RAM, so a non chip block is a failure
; and the memory is handed straight back.
        move.l  d0,a1                      ; TypeOfMem(a1 = address)
        jsr     LVO_TypeOfMem(a6)
        andi.l  #MEMF_CHIP,d0
        bne     .have_mem
        move.l  chip_base,a1               ; FreeMem(a1 = block, d0 = size)
        move.l  #CHIPDATA_SIZE,d0
        jsr     LVO_FreeMem(a6)
        clr.l   chip_base
        bra     .no_mem
.have_mem:

; Copy the assembled payload block into the allocated memory with Exec's
; CopyMem(a0 = source, a1 = dest, d0 = size).
        lea     chipdata_begin,a0
        move.l  chip_base,a1
        move.l  #CHIPDATA_SIZE,d0
        jsr     LVO_CopyMem(a6)

; Re-base the runtime pointer table: each entry is the assembled address of a
; chipdata label, rewritten to chip_base + (address - chipdata_begin).
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
        moveq   #1,d0
        rts
.no_mem:
        moveq   #0,d0
        rts

; --- raster helpers ---------------------------------------------------------

; BeamLine: the current PAL line number.
; a6 = CUSTOM. Returns d0 = 0..311. Clobbers d0 only.
BeamLine:
        move.w  DMACONR(a6),d0             ; dummy read: the Agnus needs a bus cycle before VPOSR
        move.w  VPOSR(a6),d0               ; bit 0 = vertical bit 8
        swap    d0
        move.w  VHPOSR(a6),d1              ; bits 15..8 = vertical bits 7..0
        lsr.w   #8,d1
        or.w    d1,d0
        andi.w  #$01FF,d0
        rts

; WaitFrameSync: one frame per call, on both 312 and 313 line PAL frames.
; The beam is at line >= FRAME_SYNC_LINE when the display window is done.
; Two phases: leave the region, then re-enter it, so a frame that finishes
; below the line is not counted twice.
; Clobbers d0, d1.
WaitFrameSync:
.leave:
        jsr     BeamLine
        cmp.w   #FRAME_SYNC_LINE,d0
        bhs     .leave
.enter:
        jsr     BeamLine
        cmp.w   #FRAME_SYNC_LINE,d0
        bhs     .done
        tst.w   d1
        bra     .enter
.done:
        rts

; WaitLines: wait for d3.b raster lines to pass.
; a6 = CUSTOM. Clobbers d0, d1.
WaitLines:
        moveq   #0,d1
.wline:
        jsr     BeamLine
        sub.w   d1,d0
        cmp.w   d3,d0
        blt     .wline
        rts

; --- scene modules (must precede _start for VASM single-pass bsr) ----------
        include "copper.s"
        include "scene_wire.s"
        include "scene_stars.s"
        include "scene_sprites.s"
        include "scene_logo.s"
        include "scene_copperbars.s"
        include "scene_scroller.s"
        include "modplayer.s"

; Chip RAM payload (must come after all code so the code section is complete)
        include "chipdata.s"

        xdef    _start
_start:
        movem.l d0-d7/a0-a6,-(sp)

; --- capture the system display state ---------------------------------------
; COP1LC is a write side custom register and cannot be read back, so the
; documented system startup list pointer is taken from GfxBase->copinit.
; All data below is addressed absolutely: the hunk loader relocates it, whereas
; PC-relative addressing cannot reach another hunk and cannot be a destination.
        move.l  4.w,a6
        lea     gfx_name,a1                 ; OpenLibrary(a1 = name, d0 = version)
        moveq   #0,d0                       ; (OldOpenLibrary is obsolete and traps under AROS)
        jsr     LVO_OpenLibrary(a6)
        move.l  d0,gfx_base
        beq     .start_open_fail
        move.l  d0,a0
        move.l  GfxBase_ActiView(a0),old_view
        move.l  GfxBase_copinit(a0),old_copper

; --- move every DMA visible payload into chip RAM ---------------------------
; Done while interrupts are still enabled: AllocMem must not be called from a
; Forbid/Disable section. The copy makes the demo work even if the loader
; ignored the data_c chip memory flag.
        jsr     AllocChipMem
        tst.l   d0
        beq     .start_alloc_fail

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
        move.l  4.w,a6                     ; library base travels in a6, as on every Amiga library
        jsr     LVO_Forbid(a6)
        jsr     LVO_Disable(a6)
        lea     CUSTOM,a6

        move.w  #$7FFF,INTENA(a6)          ; clear every interrupt enable
        move.w  #$7FFF,INTREQ(a6)          ; acknowledge every interrupt
        move.w  #DMAF_ALL,DMACON(a6)       ; stop all DMA
        move.w  #$7FFF,ADKCON(a6)          ; clear every ADKCON bit: no UART/disk mods

        jsr     ClearScreen
        jsr     DrawLogo
        jsr     InitStars
        jsr     PatchCopper
        jsr     InitSprites
        jsr     MOD_Init

        move.l  ptr_copper,d0
        move.l  d0,COP1LCH(a6)
        move.w  #0,COPJMP1(a6)
; Blitter and sprite DMA are on for the wireframe and the ball ring. Audio DMA stays off here: a channel enabled before MOD_Row has loaded its
; location and length would play 128 KB of arbitrary memory as noise. Each
; channel is switched on by its first note.
        move.w  #(DMAF_SETCLR|DMAF_MASTER|DMAF_RASTER|DMAF_COPPER|DMAF_BLITTER|DMAF_SPRITE),DMACON(a6)

; --- main loop --------------------------------------------------------------
; One iteration per PAL frame: WaitFrameSync returns as the beam leaves the
; display window, so everything drawn below lands in the frame shown next.
.start_main:
        jsr     WaitFrameSync
        jsr     BlitWait; last frame's wireframe blits must be finished



        jsr     WireSwap; show the buffer drawn last frame



        addq.w  #1,frame_no
        jsr     UpdateWave; Copper rows above the beam first



        jsr     UpdateBars
        jsr     UpdateSprites; also before the beam reaches the ring



        jsr     UpdateRaster
        jsr     UpdateStars
        jsr     UpdateScroller
        jsr     MOD_Tick; (timing-critical drawing first: the tick may wait on the blitter-free Paula setup)



        jsr     DrawWire; draw the next frame into the hidden buffer



        btst    #6,CIAAPRA                 ; left mouse button, active low
        bne     .start_main

; --- teardown ---------------------------------------------------------------
; Stop the demo first, then hand the View back, then the Copper: LoadView only
; installs the View, it does not restart the system Copper list.
        lea     CUSTOM,a6
        jsr     BlitWait; no blit may still be writing chip RAM



        jsr     MOD_Stop
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

; Restore the saved register values as SET/CLR writes, which is the only way
; to write the read-side DMACONR/INTENAR/ADKCONR state back. Audio DMA is
; deliberately left off: Paula location/length state is not snapshottable.
; BPLCON0/1/2 and the modulos are not restored by hand: LoadView and the
; restarted system Copper list rewrite them on the next frame.
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

; The vertical-blank interrupt must be enabled again before the first WaitTOF: WaitTOF
; sleeps until that interrupt fires, so waiting with INTENA still masked hangs forever.
        move.l  4.w,a6
        jsr     LVO_Enable(a6)             ; interrupts before any wait
        jsr     LVO_Permit(a6)

        move.l  gfx_base,a6
        jsr     LVO_WaitTOF(a6)
        jsr     LVO_WaitTOF(a6)
        jsr     LVO_DisownBlitter(a6)

; The hardware no longer reads the payload block, so it can be returned.
        move.l  4.w,a6
        move.l  chip_base,a1               ; FreeMem(a1 = block, d0 = size)
        move.l  #CHIPDATA_SIZE,d0
        jsr     LVO_FreeMem(a6)

        move.l  gfx_base,a1                ; CloseLibrary(a1 = library)
        jsr     LVO_CloseLibrary(a6)
        movem.l (sp)+,d0-d7/a0-a6
        moveq   #RETURN_OK,d0
        rts

.start_open_fail:
        movem.l (sp)+,d0-d7/a0-a6
        moveq   #RETURN_FAIL,d0
        rts

.start_alloc_fail:
        move.l  4.w,a6
        move.l  gfx_base,a1
        jsr     LVO_CloseLibrary(a6)
        movem.l (sp)+,d0-d7/a0-a6
        moveq   #RETURN_FAIL,d0
        rts
