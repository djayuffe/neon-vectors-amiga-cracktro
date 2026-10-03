; Wireframe: a regular icosahedron, 7-bit fixed rotation, perspective, blitter line mode.
BlitWait:                                  ; a6 = CUSTOM
        btst    #6,DMACONR(a6)             ; dummy read: older Agnus revisions need it
.w:
        btst    #6,DMACONR(a6)             ; BBUSY
        bne     .w
        rts

; ---------------------------------------------------------------------------
DrawWire:
        lea     CUSTOM,a6
        move.l  ptr_screen,a0
        moveq   #0,d0
        move.w  wire_front,d0
        eori.w  #1,d0                      ; the hidden buffer
        addq.w  #1,d0
        mulu    #PLANE_SIZE,d0
        adda.l  d0,a0                      ; a0 = hidden wireframe buffer

        jsr     BlitWait
        move.w  #$0100,BLTCON0(a6)         ; D only, minterm 0: clear
        move.w  #0,BLTCON1(a6)
        move.w  #0,BLTDMOD(a6)
        lea     MID_Y0*SCREEN_W_BYTES(a0),a1
        move.l  a1,BLTDPTH(a6)
        move.w  #(MID_H<<6)|(SCREEN_W_BYTES/2),BLTSIZE(a6)

        addq.w  #1,ang
; Motion path: the object sways left and right and breathes towards and away from the eye.
        lea     sintab,a2
        move.w  ang,d0
        andi.w  #255,d0
        add.w   d0,d0
        move.w  0(a2,d0.w),d0
        muls    #WIRE_SWAY,d0
        asr.l   #7,d0
        addi.w  #MID_CX,d0
        move.w  d0,wire_cx
        move.w  ang,d0
        add.w   d0,d0
        andi.w  #255,d0
        add.w   d0,d0
        move.w  0(a2,d0.w),d0
        muls    #WIRE_ZOOM,d0
        asr.l   #7,d0
        addi.w  #WIRE_ZOFF,d0
        move.w  d0,wire_zoff
        lea     proj,a3
; The icosahedron: one rotation matrix Rz(k) Ry(2k) Rx(k) over all 12
; vertices, one perspective pass, 30 blitter lines.
        move.w  ang,d0
        move.w  ang,d1
        add.w   d1,d1
        move.w  ang,d2
        jsr     CalcMatrix
        lea     verts,a1
        moveq   #12-1,d7
        moveq   #WIRE_S,d6
        jsr     TransformVerts
        jsr     BlitWait; the clear must be done before lines go in



        move.w  #SCREEN_W_BYTES,BLTCMOD(a6)    ; registers every line shares: set once
        move.w  #SCREEN_W_BYTES,BLTDMOD(a6)
        move.w  #$8000,BLTADAT(a6)
        move.w  #$FFFF,BLTBDAT(a6)
        move.w  #$FFFF,BLTAFWM(a6)
        move.w  #$FFFF,BLTALWM(a6)
        lea     proj,a3
        lea     edges,a4
        lea     edges_end,a5
.edge:
        moveq   #0,d4
        move.b  (a4)+,d4
        lsl.w   #2,d4
        move.w  0(a3,d4.w),d0
        move.w  2(a3,d4.w),d1
        moveq   #0,d4
        move.b  (a4)+,d4
        lsl.w   #2,d4
        move.w  0(a3,d4.w),d2
        move.w  2(a3,d4.w),d3
        jsr     BlitLine
        cmpa.l  a5,a4
        blo     .edge
        rts

; (d0.w * d1.w) >> 7, result in d0. Used for the 7 bit fixed point matrix.
Mul7:
        muls    d1,d0
        asr.l   #7,d0
        rts

; in: d0 = angle x, d1 = angle y, d2 = angle z (0..255 is a full turn)
; out: mat[0..8] = Rz * Ry * Rx, scaled by 128.  Clobbers d0-d2, a2, a4 (a1 and a3 are
; the caller's vertex pointers and must survive).
CalcMatrix:
        lea     sintab,a4
        andi.w  #255,d0
        add.w   d0,d0
        move.w  0(a4,d0.w),sx
        addi.w  #128,d0                    ; +64 entries of 2 bytes: cosine
        andi.w  #511,d0
        move.w  0(a4,d0.w),cx
        andi.w  #511,d1
        move.w  0(a4,d1.w),sy
        addi.w  #128,d1
        andi.w  #511,d1
        move.w  0(a4,d1.w),cy
        andi.w  #255,d2
        add.w   d2,d2
        move.w  0(a4,d2.w),sz
        addi.w  #128,d2
        andi.w  #511,d2
        move.w  0(a4,d2.w),cz
        lea     mat,a2
; m00 = cz*cy
        move.w  cz,d0
        move.w  cy,d1
        jsr     Mul7
        move.w  d0,(a2)
; m01 = cz*sy*sx - sz*cx
        move.w  cz,d0
        move.w  sy,d1
        jsr     Mul7
        move.w  sx,d1
        jsr     Mul7
        move.w  d0,d2
        move.w  sz,d0
        move.w  cx,d1
        jsr     Mul7
        sub.w   d0,d2
        move.w  d2,2(a2)
; m02 = cz*sy*cx + sz*sx
        move.w  cz,d0
        move.w  sy,d1
        jsr     Mul7
        move.w  cx,d1
        jsr     Mul7
        move.w  d0,d2
        move.w  sz,d0
        move.w  sx,d1
        jsr     Mul7
        add.w   d0,d2
        move.w  d2,4(a2)
; m10 = sz*cy
        move.w  sz,d0
        move.w  cy,d1
        jsr     Mul7
        move.w  d0,6(a2)
; m11 = sz*sy*sx + cz*cx
        move.w  sz,d0
        move.w  sy,d1
        jsr     Mul7
        move.w  sx,d1
        jsr     Mul7
        move.w  d0,d2
        move.w  cz,d0
        move.w  cx,d1
        jsr     Mul7
        add.w   d0,d2
        move.w  d2,8(a2)
; m12 = sz*sy*cx - cz*sx
        move.w  sz,d0
        move.w  sy,d1
        jsr     Mul7
        move.w  cx,d1
        jsr     Mul7
        move.w  d0,d2
        move.w  cz,d0
        move.w  sx,d1
        jsr     Mul7
        sub.w   d0,d2
        move.w  d2,10(a2)
; m20 = -sy
        move.w  sy,d0
        neg.w   d0
        move.w  d0,12(a2)
; m21 = cy*sx
        move.w  cy,d0
        move.w  sx,d1
        jsr     Mul7
        move.w  d0,14(a2)
; m22 = cy*cx
        move.w  cy,d0
        move.w  cx,d1
        jsr     Mul7
        move.w  d0,16(a2)
        rts

; in: a1 = vertices (x.w, y.w, z.w), d7 = count - 1, d6 = coordinate magnitude, a3 = output
; Vertex coordinates are 0 or +-d6 (the icosahedron reaches +-42), so the
; rotation needs no multiplication per vertex: the nine products matrix * d6
; are formed once and a vertex is the sum of +-columns. The result equals the
; full matrix product exactly. Then the
; perspective projection: screen = centre + r * WIRE_D / (z + wire_zoff) via a reciprocal
; table. a1 and a3 are left after the last vertex so objects can be chained.
; Clobbers d0-d6, a2, a4, a5.
TransformVerts:
        lea     mat,a2
        lea     tcol,a5
        moveq   #0,d0                      ; column
.col:
        move.w  0(a2),d1                   ; the three rows of column d0: mat[row*3+col]
        muls    d6,d1
        move.l  d1,0(a5)
        move.w  6(a2),d1
        muls    d6,d1
        move.l  d1,4(a5)
        move.w  12(a2),d1
        muls    d6,d1
        move.l  d1,8(a5)
        addq.l  #2,a2
        lea     12(a5),a5
        addq.w  #1,d0
        cmp.w   #3,d0
        blo     .col
        lea     recip_wire,a4
        lea     tcol,a5
.tv:
        moveq   #0,d3                      ; x'
        moveq   #0,d4                      ; y'
        moveq   #0,d5                      ; z'
        move.w  (a1)+,d0
        beq     .nx
        bmi     .mx
        add.l   0(a5),d3
        add.l   4(a5),d4
        add.l   8(a5),d5
        bra     .nx
.mx:
        sub.l   0(a5),d3
        sub.l   4(a5),d4
        sub.l   8(a5),d5
.nx:
        move.w  (a1)+,d0
        beq     .ny
        bmi     .my
        add.l   12(a5),d3
        add.l   16(a5),d4
        add.l   20(a5),d5
        bra     .ny
.my:
        sub.l   12(a5),d3
        sub.l   16(a5),d4
        sub.l   20(a5),d5
.ny:
        move.w  (a1)+,d0
        beq     .nz
        bmi     .mz
        add.l   24(a5),d3
        add.l   28(a5),d4
        add.l   32(a5),d5
        bra     .nz
.mz:
        sub.l   24(a5),d3
        sub.l   28(a5),d4
        sub.l   32(a5),d5
.nz:
        asr.l   #7,d3                      ; rotated x
        asr.l   #7,d4                      ; rotated y
        asr.l   #7,d5                      ; rotated z
        add.w   wire_zoff,d5               ; distance from the eye
        add.w   d5,d5
        move.w  0(a4,d5.w),d5              ; WIRE_D * 256 / distance
        muls    d5,d3
        asr.l   #8,d3
        add.w   wire_cx,d3
        muls    d5,d4
        asr.l   #8,d4
        addi.w  #MID_CY,d4
        move.w  d3,(a3)+
        move.w  d4,(a3)+
        dbra    d7,.tv
        rts

; Draw a line with the blitter in line mode (Hardware Reference Manual, "Line Mode").
; in: d0 = x1, d1 = y1, d2 = x2, d3 = y2, a0 = bitplane (40 bytes per row), a6 = CUSTOM
; The endpoints must be on the bitplane: there is no clipping. DrawWire presets the
; registers that never change between lines (A and B data, word masks, C/D modulo).
; Octant bits (BLTCON1 bits 4-2) come from the manual's table 6-3; dmaj/dmin are the
; larger/smaller of |dx|, |dy|; BLTAPT = 4*dmin - 2*dmaj, BLTAMOD = 4*(dmin-dmaj),
; BLTBMOD = 4*dmin; BLTSIZE = (dmaj+1 rows, 2 words). ONEDOT is left clear, which
; is what makes shallow lines solid (it is only for area-fill edges).
BlitLine:
        move.w  d1,d6
        lsl.w   #3,d6                      ; y*8
        move.w  d6,d7
        lsl.w   #2,d7                      ; y*32
        add.w   d7,d6                      ; y*40
        move.w  d0,d7
        lsr.w   #3,d7
        andi.w  #$FFFE,d7                  ; word containing the first pixel
        add.w   d7,d6
        lea     0(a0,d6.w),a1
        sub.w   d0,d2                      ; dx
        sub.w   d1,d3                      ; dy
        moveq   #0,d4                      ; bit 0: left, bit 1: up, bit 2: steep
        tst.w   d2
        bpl     .dxpos
        neg.w   d2
        addq.w  #1,d4
.dxpos:
        tst.w   d3
        bpl     .dypos
        neg.w   d3
        addq.w  #2,d4
.dypos:
        cmp.w   d2,d3
        bls     .shallow                   ; |dy| <= |dx|: x is the long axis
        exg     d2,d3                      ; d2 = dmaj, d3 = dmin
        addq.w  #4,d4
.shallow:
        lea     octants,a2
        move.b  0(a2,d4.w),d4              ; BLTCON1 octant bits + LINE
        move.w  d3,d5
        asl.w   #2,d5                      ; 4 * dmin
        move.w  d2,d7
        asl.w   #2,d7                      ; 4 * dmaj
        move.w  d7,d6
        asr.w   #1,d6                      ; 2 * dmaj
        neg.w   d6
        add.w   d5,d6                      ; 4*dmin - 2*dmaj
        bpl     .nosign
        ori.w   #$0040,d4                  ; SIGN
.nosign:
        move.w  d5,d1
        sub.w   d7,d1                      ; BLTAMOD = 4*(dmin - dmaj)
        andi.w  #15,d0
        ror.w   #4,d0                      ; A shift = x1 & 15, in bits 15-12
        ori.w   #$0BCA,d0                  ; use A, C, D; D = A*B + ~A*C
        addq.w  #1,d2
        lsl.w   #6,d2
        addq.w  #2,d2                      ; BLTSIZE
        ext.l   d6
        btst    #6,DMACONR(a6)
.bw:
        btst    #6,DMACONR(a6)
        bne     .bw
        move.w  d0,BLTCON0(a6)
        move.w  d4,BLTCON1(a6)
        move.l  d6,BLTAPTH(a6)
        move.w  d1,BLTAMOD(a6)
        move.w  d5,BLTBMOD(a6)
        move.l  a1,BLTCPTH(a6)
        move.l  a1,BLTDPTH(a6)
        move.w  d2,BLTSIZE(a6)
        rts

