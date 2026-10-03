; Sprite ball ring: eight balls on a tilted, rolling ring, depth-sorted onto the channels.
InitSprites:
        move.l  ptr_sprites,a1
        moveq   #NBALLS-1,d7
.sprite:
        lea     ball_bitmaps,a2
        moveq   #16,d2
        bsr     .page
        lea     64+ball_bitmaps,a2
        moveq   #12,d2
        bsr     .page
        lea     112+ball_bitmaps,a2
        moveq   #8,d2
        bsr     .page
        dbra    d7,.sprite
        rts
.page:                                     ; a1 = page, a2 = bitmap, d2 = lines; a1 advances one page
        move.l  a1,a3
        clr.l   (a3)+                      ; header, set per frame
        move.w  d2,d0
        subq.w  #1,d0
.l:
        move.l  (a2)+,(a3)+
        dbra    d0,.l
        clr.l   (a3)                       ; terminator
        lea     SPR_BYTES(a1),a1
        rts

; in: d0 = angle; a4 = sintab. out: d1 = sin, d2 = cos (scaled by 127)
SinCos:
        andi.w  #255,d0
        add.w   d0,d0
        move.w  0(a4,d0.w),d1
        addi.w  #128,d0
        andi.w  #511,d0
        move.w  0(a4,d0.w),d2
        rts

UpdateSprites:
        lea     sintab,a4
        move.w  frame_no,d0
        add.w   d0,d0                      ; the tilt wobbles with 2 * frame
        jsr     SinCos
        asr.w   #4,d1
        addi.w  #RING_TILT,d1
        move.w  d1,d0                      ; tilt angle
        jsr     SinCos
        move.w  d1,r_stilt
        move.w  d2,r_ctilt
        move.w  frame_no,d0                ; roll = frame
        jsr     SinCos
        move.w  d1,r_sroll
        move.w  d2,r_croll
; coefficients
        move.w  r_croll,r_a
        move.w  r_stilt,d0
        muls    r_sroll,d0
        asr.l   #7,d0
        move.w  d0,r_b
        move.w  r_sroll,r_c
        move.w  r_stilt,d0
        muls    r_croll,d0
        asr.l   #7,d0
        neg.w   d0
        move.w  d0,r_d
        move.w  r_ctilt,r_f
; the balls
        lea     ball_zc,a1
        lea     ball_sx,a2
        lea     ball_sy,a3
        lea     recip_wire,a5
        moveq   #0,d7                      ; ball number
.ball:
        move.w  frame_no,d0
        move.w  d0,d1
        add.w   d1,d1
        add.w   d1,d0                      ; 3 * frame: the spin
        move.w  d7,d1
        lsl.w   #5,d1                      ; 32 steps between balls
        add.w   d1,d0
        andi.w  #255,d0
        lsl.w   #2,d0
        lea     ring_tab,a0
        move.w  0(a0,d0.w),d2              ; x0 = RING_R * cos >> 7
        move.w  2(a0,d0.w),d1              ; z0 = RING_R * sin >> 7
        move.w  d2,d3
        muls    r_a,d3
        move.w  d1,d4
        muls    r_b,d4
        add.l   d4,d3
        asr.l   #7,d3                      ; x''
        move.w  d2,d4
        muls    r_c,d4
        move.w  d1,d5
        muls    r_d,d5
        add.l   d5,d4
        asr.l   #7,d4                      ; y''
        muls    r_f,d1
        asr.l   #7,d1                      ; z''
        addi.w  #WIRE_ZOFF,d1              ; distance
        move.w  d1,(a1)+
        add.w   d1,d1
        move.w  0(a5,d1.w),d1              ; D*256/distance
        muls    d1,d3
        asr.l   #8,d3
        add.w   wire_cx,d3
        move.w  d3,(a2)+                   ; screen x
        muls    d1,d4
        asr.l   #8,d4
        addi.w  #MID_CY,d4
        move.w  d4,(a3)+                   ; screen y
        addq.w  #1,d7
        cmp.w   #NBALLS,d7
        blo     .ball
; stable insertion sort of the ball numbers by distance, nearest first
        lea     ball_order,a1
        moveq   #0,d0
.init:
        move.w  d0,(a1)+
        addq.w  #1,d0
        cmp.w   #NBALLS,d0
        blo     .init
        lea     ball_order,a1
        lea     ball_zc,a2
        moveq   #1,d6                      ; j
.sj:
        move.w  d6,d0
        add.w   d0,d0
        move.w  0(a1,d0.w),d4              ; key = order[j]
        move.w  d4,d0
        add.w   d0,d0
        move.w  0(a2,d0.w),d5              ; its distance
        move.w  d6,d3                      ; insertion position
.si:
        tst.w   d3
        beq     .place
        move.w  d3,d0
        subq.w  #1,d0
        add.w   d0,d0                      ; byte offset of order[position-1]
        move.w  0(a1,d0.w),d1
        add.w   d1,d1
        move.w  0(a2,d1.w),d2              ; distance of that ball
        cmp.w   d5,d2
        ble     .place                     ; not further than the key: stable, stop
        move.w  0(a1,d0.w),2(a1,d0.w)      ; shift it up
        subq.w  #1,d3
        bra     .si
.place:
        move.w  d3,d0
        add.w   d0,d0
        move.w  d4,0(a1,d0.w)
        addq.w  #1,d6
        cmp.w   #NBALLS,d6
        blo     .sj
; write the sprites, rank 0 = nearest = sprite 0
        moveq   #0,d7
.wr:
        move.w  d7,d0
        add.w   d0,d0
        lea     ball_order,a1
        move.w  0(a1,d0.w),d6              ; ball number
        move.w  d6,d0
        add.w   d0,d0
        lea     ball_zc,a1
        move.w  0(a1,d0.w),d3              ; distance
        lea     ball_sx,a1
        move.w  0(a1,d0.w),d4              ; screen x
        lea     ball_sy,a1
        move.w  0(a1,d0.w),d5              ; screen y
        moveq   #16,d2
        moveq   #0,d6                      ; size class
        cmp.w   #BALL_NEAR,d3
        blt     .sized
        moveq   #12,d2
        moveq   #1,d6
        cmp.w   #BALL_MID,d3
        blt     .sized
        moveq   #8,d2
        moveq   #2,d6
.sized:
        move.w  d5,d0
        addi.w  #44,d0                     ; display line of the ball's centre
        move.w  d2,d1
        lsr.w   #1,d1
        sub.w   d1,d0                      ; VSTART
        move.w  d0,d1
        add.w   d2,d1                      ; VSTOP
        move.w  d4,d3
        addi.w  #$81-8,d3                  ; HSTART: $81 is the window's left edge, minus half the sprite
        move.w  d0,d4
        andi.w  #255,d4
        lsl.w   #8,d4
        move.w  d3,d5
        lsr.w   #1,d5
        andi.w  #255,d5
        or.w    d5,d4                      ; SPRxPOS
        move.w  d1,d5
        andi.w  #255,d5
        lsl.w   #8,d5
        btst    #8,d0
        beq     .v0
        ori.w   #4,d5
.v0:
        btst    #8,d1
        beq     .v1
        ori.w   #2,d5
.v1:
        andi.w  #1,d3
        or.w    d3,d5                      ; SPRxCTL
; page = sprites + (rank * 3 + size class) * SPR_BYTES, class 0 = 16 px, 1 = 12, 2 = 8
        move.w  d7,d0
        add.w   d0,d0
        add.w   d7,d0                      ; rank * 3
        add.w   d6,d0                      ; + size class
        mulu    #SPR_BYTES,d0
        move.l  ptr_sprites,a1
        adda.l  d0,a1
        move.w  d4,(a1)
        move.w  d5,2(a1)                   ; header words
        move.l  ptr_cop_spr,a2             ; point this sprite's Copper pointer pair at the page
        move.w  d7,d0
        lsl.w   #3,d0
        adda.w  d0,a2
        move.l  a1,d0
        move.w  d0,6(a2)
        swap    d0
        move.w  d0,2(a2)
        addq.w  #1,d7
        cmp.w   #NBALLS,d7
        blo     .wr
        rts

; ---------------------------------------------------------------------------
; Wireframe. A cube (objects' vertices 0..7) and an octahedron (8..13) rotate in
; opposite directions. Each frame: the hidden buffer's band is cleared by the
; blitter while the CPU builds the rotation matrices and projects the vertices,
; then every edge is drawn with the blitter in line mode. The buffer becomes
; visible only after WireSwap, so the picture never shows a half-drawn frame.
; ---------------------------------------------------------------------------
