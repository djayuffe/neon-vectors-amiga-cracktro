; ---------------------------------------------------------------------------
; Copper pointer patching. The Copper list in the data_c block was assembled
; with zero BPLxPTL/PTH words; every frame the currently visible buffer pair
; is written into the copy that lives in chip RAM.
; ---------------------------------------------------------------------------

; The Copper plane pointers are 2 bytes before the plane (the extra fetch word).
; The screen block holds plane 0, the two buffers of plane 1, plane 2 and the
; two buffers of plane 3, in that order; planes 1 and 3 (the 3D object planes)
; are double-buffered and the display uses whichever buffer of each is
; currently in front.
PatchCopper:
        move.l  ptr_cop_bpl1,a1
        move.l  ptr_screen,d3
        subq.l  #2,d3                      ; every plane starts one word early: BPLCON1 scroll fetches it
        move.l  d3,d0
        move.w  d0,6(a1)                   ; BPL1PTL
        swap    d0
        move.w  d0,2(a1)                   ; BPL1PTH
        moveq   #0,d0
        move.w  wire_front,d0
        addq.w  #1,d0
        mulu    #PLANE_SIZE,d0
        add.l   d3,d0
        move.w  d0,14(a1)                  ; BPL2PTL: plane 1, the front buffer
        swap    d0
        move.w  d0,10(a1)                  ; BPL2PTH
        move.l  d3,d0
        addi.l  #PLANE_SIZE*3,d0
        move.w  d0,22(a1)                  ; BPL3PTL
        swap    d0
        move.w  d0,18(a1)                  ; BPL3PTH
        moveq   #0,d0
        move.w  wire_front,d0
        addq.w  #4,d0
        mulu    #PLANE_SIZE,d0
        add.l   d3,d0
        move.w  d0,30(a1)                  ; BPL4PTL: plane 3, the front buffer
        swap    d0
        move.w  d0,26(a1)                  ; BPL4PTH
        rts

; Flip the wireframe buffers and point the Copper at the one drawn last frame.
WireSwap:
        eori.w  #1,wire_front
        jsr     PatchCopper
        rts

; ---------------------------------------------------------------------------
; All DMA visible payloads. The block is copied into freshly allocated chip
; RAM at run time, so the loader may place it anywhere without breaking the
; Copper, the bitplanes, the Paula samples or the silent terminal word.
;
; Copper WAIT is a two word instruction: word one is the beam position with
; bit0 set, word two is the comparison mask with bit0 clear and bit 15 set for
; blitter finished. $xx01,$FFFE therefore waits for vertical position $xx with
; every vertical and horizontal bit compared, and $FFFF,$FFFE never matches,
; which parks the list until the next vertical blank reloads COP1LC.
; ---------------------------------------------------------------------------
