; ---------------------------------------------------------------------------
; NEON VECTORS row/tick ProTracker replay core (refactored).
;
; 4-channel M.K., PAL VBlank tick = 50 Hz = ProTracker BPM 125 tick rate.
; Supported commands: note + sample + period, sample default volume, Cxx
; volume, F01..F1F speed (the generated module uses F06) and A0x slide-up,
; x = 1..15 periods per row. A1x (slide down) is deliberately unsupported,
; as is BPM mode (F20 and above); the validator whitelists exactly what is
; implemented here, so a module cannot ask for an effect this player drops.
;
; Slide semantics: an A0x event stores x in mod_slide[channel]. The stored
; step is added to the period on EVERY row that retriggers the channel
; (period = period + step, clamped to 113..856). A retriggered row that
; carries any other effect resets the step to 0, and a period-0 row (note
; off) resets it as well.
;
; The pattern base is found by searching for "M.K." from offset 1080
; forward (at most 64 bytes) and taking the next 4 aligned address; with
; the generated module (header exactly 1084 bytes) the marker sits at
; 1080..1083 and the base lands on 1084. If the marker is not found the
; base falls back to a0+1084.
;
; Paula channel registers are addressed through a1 = CUSTOM+AUD0LCH+ch*16:
; 0(a1) location, 4(a1) length in words, 6(a1) period, 8(a1) volume. The
; custom register offsets are too large for the 8 bit displacement of an
; indexed addressing mode, so the channel base is formed with LEA.
;
; Only CPU side work happens here, so it is safe to run with interrupts
; off. MOD_Row clobbers d0-d7 and a0-a6; MOD_Init returns d0 = 1 ok / 0 bad.
; ---------------------------------------------------------------------------

MOD_Init:
        move.l  ptr_mod,a0
        moveq   #0,d0
        move.b  950(a0),d0                 ; song length
        beq     .bad
        cmp.b   #128,d0
        bhi     .bad
        move.b  d0,mod_songlen

; The pattern base follows the "M.K." marker: scan at most 64 bytes for it
; and take the next 4 aligned address.
        lea     1080(a0),a1
        moveq   #64,d7
.mark:
        cmpi.b  #$4D,(a1)                  ; 'M'
        bne     .marknext
        cmpi.b  #$2E,1(a1)                 ; '.'
        bne     .marknext
        cmpi.b  #$4B,2(a1)                 ; 'K'
        bne     .marknext
        move.l  a1,a2
        addq.l  #4,a2
        move.l  a2,d0
        andi.l  #$FFFFFFFC,d0              ; next 4 aligned address
        move.l  d0,a2
        bra     .markdone
.marknext:
        addq.l  #1,a1
        dbra    d7,.mark
        move.l  a0,a2
        moveq   #0,d0
        move.w  #1084,d0
        adda.l  d0,a2                      ; marker not found: use a0+1084
.markdone:
        move.l  a2,mod_pattern_base

; Build the absolute sample starts from the sample lengths, so a row only
; has to index a table. All 31 instruments are valid; the generated module
; fills the unused slots with a 2 byte silence sample.
        move.l  a2,a4
        lea     20(a0),a3
        lea     mod_sample_ptrs,a2
        moveq   #30,d7
.sptr:
        move.l  a4,(a2)+
        moveq   #0,d0
        move.w  22(a3),d0                  ; sample length, words
        add.l   d0,d0                      ; words to bytes
        adda.l  d0,a4
        lea     30(a3),a3
        dbra    d7,.sptr

        clr.b   mod_order
        clr.b   mod_row
        move.b  #5,mod_tick                ; force row 0 on the first frame
        move.b  #6,mod_speed
        moveq   #0,d3
        lea     mod_slide,a2
        move.w  d3,(a2)
        move.w  d3,2(a2)
        move.w  d3,4(a2)
        move.w  d3,6(a2)
        moveq   #1,d0
        rts
.bad:
        clr.b   mod_songlen
        moveq   #0,d0
        rts

; One 50 Hz tracker tick. speed ticks per row.
MOD_Tick:
        tst.b   mod_songlen
        beq     .done
        addq.b  #1,mod_tick
        move.b  mod_tick,d0
        cmp.b   mod_speed,d0
        blo     .done
        clr.b   mod_tick
        jsr     MOD_Row
.done:
        rts

MOD_Row:
        move.l  ptr_mod,a0
        move.l  mod_pattern_base,a2
        moveq   #0,d0
        move.b  mod_order,d0
        moveq   #0,d1
        lea     952(a0),a3
        move.b  0(a3,d0.w),d1
        lsl.l   #8,d1
        lsl.l   #2,d1                      ; pattern * 1024
        adda.l  d1,a2
        moveq   #0,d2
        move.b  mod_row,d2
        lsl.w   #4,d2                      ; row * 16
        adda.l  d2,a2

        lea     CUSTOM,a6
        clr.w   mod_trigger_mask
        moveq   #0,d6
.ch:
        lea     CUSTOM+AUD0LCH,a1
        move.w  d6,d7
        lsl.w   #4,d7
        lea     0(a1,d7.w),a1              ; a1 = this channel's Paula registers

        move.l  (a2)+,d0
        move.l  d0,d1
        swap    d1
        andi.w  #$0FFF,d1                  ; period
        move.l  d0,d2
        rol.l   #8,d2                      ; sample number, high nibble
        andi.w  #$00F0,d2
        move.w  d0,d3
        lsr.w   #8,d3
        lsr.w   #4,d3                      ; sample number, low nibble
        or.w    d3,d2                      ; d2 = sample number
        move.l  d0,d3
        lsr.w   #8,d3
        andi.w  #$000F,d3                  ; d3 = effect
        move.w  d0,d4
        andi.w  #$00FF,d4                  ; d4 = parameter

; a3 = this channel's slide slot for the rest of the row.
        move.w  d6,d5
        lsl.w   #1,d5
        lea     mod_slide,a3

        tst.w   d1
        beq     .noteoff

        cmp.w   #$0A,d3
        beq     .slide
        move.w  #0,0(a3)
        bra     .slideend
.slide:
; A0x, x = 1..15: the step persists until a retriggered row carries any
; other effect or a note off.
        cmp.w   #15,d4
        bhi     .slidebad
        ext.w   d4
        move.w  d4,0(a3)
        bra     .slideend
.slidebad:
        move.w  #0,0(a3)
.slideend:
        move.w  0(a3),d5
        add.w   d5,d1
        cmpi.w  #113,d1
        blt     .pclamp
        cmpi.w  #856,d1
        bhi     .pclamp
        bra     .pdone
.pclamp:
        cmpi.w  #113,d1
        blt     .pmin
        move.w  #856,d1
        bra     .pdone
.pmin:
        moveq   #113,d1
.pdone:
        move.w  d1,6(a1)

        tst.w   d2
        beq     .effects
        cmp.w   #31,d2
        bhi     .effects
        subq.w  #1,d2                      ; zero based sample
        move.w  d2,d5
        lsl.w   #2,d5
        lea     mod_sample_ptrs,a4
        move.l  0(a4,d5.w),a5
        move.w  d2,d5
        mulu    #30,d5
        lea     20(a0,d5.w),a6             ; a6 = this instrument header

; Sample default volume also applies to sample-only rows.
        moveq   #0,d5
        move.b  25(a6),d5
        cmp.w   #64,d5
        bls     .volok
        moveq   #64,d5
.volok:
        move.w  d5,8(a1)

; Clear this channel's DMA bit first: writing location/length/period while
; the channel is fetching would restart the sample at a half updated
; address.
        moveq   #1,d5
        lsl.w   d6,d5
        move.w  d5,DMACON(a6)
        or.w    d5,mod_trigger_mask
        move.l  a5,(a1)
        move.w  22(a6),d5                  ; sample length, words; AUDxLEN
                                            ; counts words
        cmp.w   #1,d5
        bhs     .lenok
        moveq   #1,d5                      ; 0 would mean 65536 words
.lenok:
        move.w  d5,4(a1)

; Cache the loop location/length and install it after DMA has latched the
; initial location and length.
        moveq   #0,d1
        move.w  26(a6),d1                  ; loop start, words
        add.l   d1,d1
        adda.l  d1,a5
        move.w  28(a6),d1
        cmp.w   #1,d1
        bhi     .loopok
; ProTracker loop length 0 or 1 means one-shot. Point Paula at a real
; silent chip RAM word instead of at the end of the sample data.
        move.l  ptr_silence,a5
        moveq   #1,d1
.loopok:
        move.w  d6,d5
        lsl.w   #2,d5
        lea     mod_loop_ptrs,a4
        move.l  a5,0(a4,d5.w)
        move.w  d6,d5
        add.w   d5,d5
        lea     mod_loop_lens,a4
        move.w  d1,0(a4,d5.w)
        bra     .next
.noteoff:
        move.w  #0,0(a3)
        bra     .next
.effects:
        cmp.w   #$0C,d3
        bne     .fxf
        cmp.w   #64,d4
        bls     .cok
        moveq   #64,d4
.cok:
        move.w  d4,8(a1)
.fxf:
        cmp.w   #$0F,d3
        bne     .next
        tst.w   d4
        beq     .next
        cmp.w   #31,d4
        bhi     .next                      ; BPM mode is deliberately unsupported
        move.b  d4,mod_speed
.next:
        addq.w  #1,d6
        cmp.w   #4,d6
        blo     .ch

; Re-enable the triggered channels together. Two raster lines are far more
; than the documented audio DMA settling interval.
        tst.w   mod_trigger_mask
        beq     .advance
        moveq   #2,d3
        jsr     WaitLines
        move.w  mod_trigger_mask,d0
        ori.w   #DMAF_SETCLR,d0
        move.w  d0,DMACON(a6)
        moveq   #2,d3
        jsr     WaitLines

; Paula has now fetched the initial location and length, so the loop or the
; silent terminal word can replace them.
        moveq   #0,d6
.loopregs:
        moveq   #1,d0
        lsl.w   d6,d0
        and.w   mod_trigger_mask,d0
        beq     .lnext
        lea     CUSTOM+AUD0LCH,a1
        move.w  d6,d7
        lsl.w   #4,d7
        lea     0(a1,d7.w),a1
        move.w  d6,d5
        lsl.w   #2,d5
        lea     mod_loop_ptrs,a3
        move.l  0(a3,d5.w),(a1)
        move.w  d6,d5
        add.w   d5,d5
        lea     mod_loop_lens,a3
        move.w  0(a3,d5.w),4(a1)           ; words, not words minus one
.lnext:
        addq.w  #1,d6
        cmp.w   #4,d6
        blo     .loopregs

.advance:
        addq.b  #1,mod_row
        cmp.b   #64,mod_row
        blo     .ret
        clr.b   mod_row
        addq.b  #1,mod_order
        move.b  mod_order,d0
        cmp.b   mod_songlen,d0
        blo     .ret
        clr.b   mod_order
.ret:
        rts

; Stop Paula and let any in flight DMA word finish before the chipset is
; handed back, so a channel cannot keep fetching chip RAM after return.
MOD_Stop:
        lea     CUSTOM,a6
        move.w  #DMAF_AUDIO,DMACON(a6)
        moveq   #2,d3
        jsr     WaitLines
        rts

        section data,data
mod_sample_ptrs:  ds.l 31
mod_loop_ptrs:    ds.l 4
mod_loop_lens:    ds.w 4
mod_trigger_mask: dc.w 0
mod_slide:        ds.w 4
mod_songlen:      dc.b 0
mod_order:        dc.b 0
mod_row:          dc.b 0
mod_tick:         dc.b 0
mod_speed:        dc.b 6
mod_pattern_base: dc.l 0
        even
