; Scroller: sixteen MSB-first double-height font rows, shifted one pixel left per update.
UpdateScroller:
        addq.b  #1,scroll_div
        cmp.b   #2,scroll_div
        blo     .done
        clr.b   scroll_div

        move.l  ptr_screen,a0
        adda.l  #SCROLL_Y*SCREEN_W_BYTES,a0
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
        adda.l  #(SCROLL_Y*SCREEN_W_BYTES)+SCREEN_W_BYTES-1,a0
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

; ---------------------------------------------------------------------------
; Hardware sprite ring: eight shaded balls on a tilted ring that spins, rolls and
; wobbles in 3D around the wireframe. The sprite hardware draws them; the CPU only
; rewrites each sprite's small buffer (position words and a 16 line bitmap) once a
; frame, early, before the beam reaches the ring.
;
; Per ball: a point on the ring is rotated by the tilt (about x) and roll (about z),
; so with y = 0 the 3x3 matrix needs only five coefficients:
;     x'' = (x0*A + z0*B) >> 7      A = cos(roll)            B = sin(tilt)*sin(roll) >> 7
;     y'' = (x0*C + z0*D) >> 7      C = sin(roll)            D = -(sin(tilt)*cos(roll) >> 7)
;     z'' = (z0*F) >> 7             F = cos(tilt)
; and projected with the reciprocal table. Balls are sorted by distance and the nearest
; get the lowest sprite numbers (the sprite hardware puts a lower number in front), which
; also gives them the brightest sprite-pair palette. Size (16/12/8 pixels) follows distance.
; ---------------------------------------------------------------------------
; Every sprite gets three prebuilt pages (one per ball size): position words, the shaded
; ball bitmap, and the end-of-sprite zero long. Per frame only the header words of the
; chosen page and the sprite's Copper pointer change, so no bitmap is ever copied.
