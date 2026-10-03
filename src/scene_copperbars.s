; Copper-list per-frame rewrites: wavy logo rows, floor bars, animated raster colour.
UpdateWave:
        move.l  ptr_wave,a1
        lea     wave_tab,a2
        move.w  frame_no,d3
        lsl.w   #2,d3                      ; time: 4 table steps per frame
        moveq   #0,d4                      ; row phase: 3 steps per row (~85 rows per wave)
        moveq   #LOGO_H-1,d7
.w:
        move.w  d3,d0
        add.w   d4,d0
        andi.w  #255,d0
        add.w   d0,d0
        move.w  0(a2,d0.w),14(a1)          ; BPLCON1 value for this row
        lea     16(a1),a1
        addq.w  #3,d4
        dbra    d7,.w
        rts

; ---------------------------------------------------------------------------
; Copper-bar floor. The 34 floor rows (cop_bars, 8 bytes per row, COLOR00 value at +6)
; are first reset to the static ramp, then NBARS bars of 8 rows are painted over them,
; each moving on its own sine; later bars are in front.
; ---------------------------------------------------------------------------
UpdateBars:
        move.l  ptr_bars,a1
        lea     floor_base,a2
        move.l  a1,a3
        moveq   #FLOOR_H-1,d7
.base:
        move.w  (a2)+,6(a3)
        lea     8(a3),a3
        dbra    d7,.base
        lea     sintab,a2
        lea     bar_colors,a3
        moveq   #0,d6
.bar:
        move.w  frame_no,d0
        move.w  d6,d1
        addq.w  #2,d1
        mulu    d1,d0                      ; frame * (bar + 2): each bar has its own speed
        move.w  d6,d1
        lsl.w   #6,d1
        add.w   d1,d0                      ; + 64 steps of phase per bar
        andi.w  #255,d0
        add.w   d0,d0
        move.w  0(a2,d0.w),d0
        muls    #13,d0
        asr.l   #7,d0
        addi.w  #FLOOR_H/2-4,d0            ; first of the bar's 8 rows
        moveq   #8-1,d7
.row:
        tst.w   d0
        bmi     .skip
        cmp.w   #FLOOR_H,d0
        bge     .skip
        move.w  d0,d1
        lsl.w   #3,d1
        move.w  (a3),6(a1,d1.w)
.skip:
        addq.l  #2,a3
        addq.w  #1,d0
        dbra    d7,.row
        addq.w  #1,d6
        cmp.w   #NBARS,d6
        blo     .bar
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
; 3D starfield. Each star is (x, y, z); z falls by ZSPEED per frame and the star
; is projected as screen = centre + coordinate * PROJ_F / z, so near stars move
; faster and further from the centre than far ones. When z reaches ZMIN the star
; is sent to the back with a new x and y.
;
; Depth is shown with brightness, using the planes that are free in the middle
; band: far = plane 2 only, mid = plane 0 only, near = planes 0 and 2. The
; palette turns those three combinations into three brightnesses.
;
; Every star remembers the byte offset, bit mask and class (bit 0 = plane 2,
; bit 1 = plane 0) it was drawn with, so the next frame erases exactly that.
; ---------------------------------------------------------------------------
