; Logo: blit the four logo planes into the screen block (rows LOGO_Y..+LOGO_H).
ClearScreen:
        move.l  ptr_screen,a0
        moveq   #0,d0
        move.w  #SCREEN_LONGS-1,d7
.cs:
        move.l  d0,(a0)+
        dbra    d7,.cs
        rts

; The logo has four planes of LOGO_H rows. Plane 0 and 2 go into their plane, planes 1 and 3
; into both buffers of their plane (the object code only ever touches the middle band).
DrawLogo:
        move.l  ptr_logo,a0
        move.l  ptr_screen,a1
        lea     LOGO_Y*SCREEN_W_BYTES(a1),a2
        jsr     CopyLogoPlane; plane 0



        lea     PLANE_SIZE+LOGO_Y*SCREEN_W_BYTES(a1),a2
        jsr     CopyLogoPlane; plane 1, buffer 0



        lea     -(SCREEN_W_BYTES*LOGO_H)(a0),a0
        lea     PLANE_SIZE*2+LOGO_Y*SCREEN_W_BYTES(a1),a2
        jsr     CopyLogoPlane; plane 1, buffer 1



        lea     PLANE_SIZE*3+LOGO_Y*SCREEN_W_BYTES(a1),a2
        jsr     CopyLogoPlane; plane 2



        move.l  a1,a2
        adda.l  #PLANE_SIZE*4+LOGO_Y*SCREEN_W_BYTES,a2
        jsr     CopyLogoPlane; plane 3, buffer 0



        lea     -(SCREEN_W_BYTES*LOGO_H)(a0),a0
        move.l  a1,a2
        adda.l  #PLANE_SIZE*5+LOGO_Y*SCREEN_W_BYTES,a2
        jsr     CopyLogoPlane; plane 3, buffer 1



        rts

; in: a0 = source (advanced past the plane), a2 = destination
CopyLogoPlane:
        move.w  #(SCREEN_W_BYTES*LOGO_H/4)-1,d7
.c:
        move.l  (a0)+,(a2)+
        dbra    d7,.c
        rts

; Rewrite the three bitplane pointer pairs in the copied Copper list. The list is
; stored as MOVE pairs, so the register words sit at byte offsets 0/4/8/12/16/20
; and the data words that PatchCopper overwrites at 2/6, 10/14 and 18/22.
; The Copper plane pointers are 2 bytes before the plane (the extra fetch word). The
; screen block holds plane 0, the two buffers of plane 1, plane 2 and the two buffers
; of plane 3, in that order; planes 1 and 3 (the 3D object planes) are double-buffered
; and the display uses whichever buffer of each is currently in front.
