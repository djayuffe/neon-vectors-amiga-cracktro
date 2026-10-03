; Starfield: NSTARS points flying out with perspective, three depth brightnesses.
Rand:                                      ; 16 bit LCG; result in d0.w
        move.w  rng_seed,d0
        mulu    #25173,d0
        addi.l  #13849,d0
        move.w  d0,rng_seed
        rts

InitStars:
        move.w  #1,rng_seed
        lea     stars,a2
        moveq   #NSTARS-1,d7
.is:
        jsr     Rand
        andi.w  #511,d0
        subi.w  #255,d0
        move.w  d0,(a2)                    ; x -255..256
        jsr     Rand
        andi.w  #255,d0
        subi.w  #128,d0
        muls    #5,d0
        asr.l   #3,d0
        move.w  d0,2(a2)                   ; y -80..79
        jsr     Rand
        andi.w  #255,d0
        mulu    #ZRANGE,d0
        lsr.l   #8,d0
        addi.w  #ZMIN,d0
        move.w  d0,4(a2)                   ; z ZMIN..ZMIN+ZRANGE-1
        clr.w   6(a2)
        clr.b   8(a2)
        clr.b   9(a2)                      ; nothing drawn yet
        lea     STAR_SIZE(a2),a2
        dbra    d7,.is
        rts

UpdateStars:
        move.l  ptr_screen,a0              ; plane 0
        lea     PLANE_SIZE*3(a0),a1        ; plane 2
        lea     stars,a2
; Erase every star at its remembered position first, so two stars sharing a
; byte cannot cancel each other's pixel.
        moveq   #NSTARS-1,d7
.er:
        move.b  9(a2),d0
        beq     .ernext
        move.w  6(a2),d2
        move.b  8(a2),d1
        not.b   d1
        btst    #0,d0
        beq     .er0
        and.b   d1,0(a1,d2.w)
.er0:
        btst    #1,d0
        beq     .er1
        and.b   d1,0(a0,d2.w)
.er1:
        clr.b   9(a2)
.ernext:
        lea     STAR_SIZE(a2),a2
        dbra    d7,.er

        lea     stars,a2
        lea     recip_star,a3
        moveq   #NSTARS-1,d7
.dr:
        move.w  4(a2),d3
        subq.w  #ZSPEED,d3
        cmp.w   #ZMIN,d3
        bge     .zok
        addi.w  #ZRANGE,d3                 ; back to the far end, new lane
        jsr     Rand
        andi.w  #511,d0
        subi.w  #255,d0
        move.w  d0,(a2)
        jsr     Rand
        andi.w  #255,d0
        subi.w  #128,d0
        muls    #5,d0
        asr.l   #3,d0
        move.w  d0,2(a2)
.zok:
        move.w  d3,4(a2)
        move.w  d3,d6
        add.w   d6,d6
        move.w  0(a3,d6.w),d6              ; PROJ_F * 256 / z
        move.w  (a2),d0
        muls    d6,d0
        asr.l   #8,d0                      ; x * PROJ_F / z
        addi.w  #MID_CX,d0                 ; screen x
        cmp.w   #320,d0
        bhs     .skip                      ; unsigned: also catches negative x
        move.w  2(a2),d1
        muls    d6,d1
        asr.l   #8,d1
        addi.w  #MID_CY,d1                 ; screen y
        move.w  d1,d2
        subi.w  #MID_Y0,d2
        cmp.w   #MID_H,d2
        bhs     .skip
        mulu    #SCREEN_W_BYTES,d1
        move.w  d0,d2
        lsr.w   #3,d2
        add.w   d2,d1                      ; byte offset of the star
        move.w  d1,6(a2)
        andi.w  #7,d0
        moveq   #7,d2
        sub.w   d0,d2                      ; bit number, MSB first
        moveq   #1,d4
        lsl.b   d2,d4                      ; mask
        move.b  d4,8(a2)
        moveq   #3,d5                      ; near
        cmp.w   #ZNEAR,d3
        ble     .cls
        moveq   #2,d5                      ; mid
        cmp.w   #ZMID,d3
        ble     .cls
        moveq   #1,d5                      ; far
.cls:
        move.b  d5,9(a2)
        btst    #0,d5
        beq     .d0
        or.b    d4,0(a1,d1.w)
.d0:
        btst    #1,d5
        beq     .dnext
        or.b    d4,0(a0,d1.w)
        bra     .dnext
.skip:
        clr.b   9(a2)
.dnext:
        lea     STAR_SIZE(a2),a2
        dbra    d7,.dr
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
