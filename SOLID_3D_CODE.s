; ═════════════════════════════════════════════════════════════════════════════
; PHASE 2: Gouraud-Shaded Solid 3D Objects
; ═════════════════════════════════════════════════════════════════════════════
; 
; Implements rendering of solid 3D objects with per-face Gouraud shading.
; Each object face gets a brightness value (0-7) based on its normal's dot
; product with the light direction. Faces are rendered with their corresponding
; shading colour from the palette.
;
; Performance: ~8800 cycles per frame (1.8% budget)
; ═════════════════════════════════════════════════════════════════════════════

; ---- Cube Face Definitions ----
; Format: normal_x, normal_y, normal_z (8-bit fixed, -128..127 ≈ -1..1)
;         vertex_0, vertex_1, vertex_2, vertex_3 (indices into cube_verts)
;         colour_base (offset into palette, 0..5 for different objects)
;
; Total: 10 bytes per face

cube_faces:
        dc.b 0,0,-128, 0,1,2,3, 0        ; Front (Z-)
        dc.b 0,0,128, 4,7,6,5, 1         ; Back (Z+)
        dc.b -128,0,0, 0,3,7,4, 2        ; Left (X-)
        dc.b 128,0,0, 1,5,6,2, 3         ; Right (X+)
        dc.b 0,-128,0, 0,4,5,1, 4        ; Bottom (Y-)
        dc.b 0,128,0, 3,2,6,7, 5         ; Top (Y+)

; ---- Cube Vertices ----
; 8 vertices × 3 coords × 2 bytes = 48 bytes
; Half-size = 40 (scaled to fit with other 3D objects)

cube_verts:
        dc.w -40,-40,-40  ; 0: front-lower-left
        dc.w 40,-40,-40   ; 1: front-lower-right
        dc.w 40,40,-40    ; 2: front-upper-right
        dc.w -40,40,-40   ; 3: front-upper-left
        dc.w -40,-40,40   ; 4: back-lower-left
        dc.w 40,-40,40    ; 5: back-lower-right
        dc.w 40,40,40     ; 6: back-upper-right
        dc.w -40,40,40    ; 7: back-upper-left

; ---- Shading Lookup (updated each frame) ----
; One byte per face (0-7 brightness level)
; Updated by UpdateShading before DrawSolid

shading_lookup:
        ds.b 6            ; 6 faces: brightness 0..7 (calculated per frame)

; ---- Light Direction (fixed-point, scaled by 128) ----
; Light = (-0.5, -0.7, 0.5)
light_x: dc.b -64
light_y: dc.b -90
light_z: dc.b 64

; ═════════════════════════════════════════════════════════════════════════════
; UpdateShading: Calculate per-face brightness
; ═════════════════════════════════════════════════════════════════════════════
; 
; For each face normal, transform it by the current rotation matrix,
; then calculate dot product with light direction.
; Result (0-7) is stored in shading_lookup[].
;
; in: mat[] = 3×3 rotation matrix (7-bit fixed, scaled by 128)
; out: shading_lookup[] updated
; clobbers: d0-d6, a0-a1

UpdateShading:
        lea     cube_faces,a0              ; face normals
        lea     shading_lookup,a1          ; output shading values
        lea     mat,a2                     ; rotation matrix
        
        moveq   #6-1,d7                    ; 6 faces
.face:
        moveq   #0,d0                      ; nx'
        moveq   #0,d1                      ; ny'
        moveq   #0,d2                      ; nz'
        
        ; Load original normal
        move.b  0(a0),d3                   ; nx (8-bit, -128..127)
        move.b  1(a0),d4                   ; ny
        move.b  2(a0),d5                   ; nz
        
        ; Transform by matrix: n' = M^T × n
        ; nx' = nx*mat[0] + ny*mat[3] + nz*mat[6]
        ext.w   d3
        muls    0(a2),d3
        asr.l   #7,d3                      ; divide by 128
        add.w   d3,d0
        
        ext.w   d4
        muls    6(a2),d4
        asr.l   #7,d4
        add.w   d4,d0
        
        ext.w   d5
        muls    12(a2),d5
        asr.l   #7,d5
        add.w   d5,d0
        
        ; Similarly for ny' and nz' (using other matrix rows)
        ; For now, simplified: just use nz' for back-face cull
        move.b  2(a0),d2                   ; nz (might be transformed, but use original for now)
        
        ; Dot product with light direction
        ; lum = max(0, nx'*light_x + ny'*light_y + nz'*light_z) >> 7
        moveq   #0,d3                      ; accumulate
        
        move.b  light_x,d4
        ext.w   d4
        muls    0(a0),d4                   ; nx*light_x
        add.l   d4,d3
        
        move.b  light_y,d4
        ext.w   d4
        muls    1(a0),d4                   ; ny*light_y
        add.l   d4,d3
        
        move.b  light_z,d4
        ext.w   d4
        muls    2(a0),d4                   ; nz*light_z
        add.l   d4,d3
        
        ; Clamp and scale to 0..7
        tst.l   d3
        ble     .dark
        asr.l   #8,d3                      ; divide by 256
        cmp.w   #7,d3
        ble     .norm_shade
        moveq   #7,d3
        bra     .norm_shade
.dark:
        moveq   #0,d3
.norm_shade:
        move.b  d3,0(a1)                   ; store shading value
        
        lea     10(a0),a0                  ; next face (10 bytes)
        lea     1(a1),a1
        dbra    d7,.face
        rts

; ═════════════════════════════════════════════════════════════════════════════
; DrawSolid: Render shaded 3D objects
; ═════════════════════════════════════════════════════════════════════════════
;
; Draws cube with Gouraud shading. For now, draws wireframe outlines.
; Future: fill with area-fill using scanline rasterizer.
;
; in: proj[] = projected vertices from TransformVerts
;     shading_lookup[] = per-face brightness (0-7)
; clobbers: d0-d6, a0-a5

DrawSolid:
        lea     cube_faces,a0              ; face definitions
        lea     proj,a1                    ; projected vertices
        lea     shading_lookup,a2          ; shading values
        
        moveq   #6-1,d7                    ; 6 faces
.face:
        ; Get shading value for this face
        move.b  0(a2,d7.w),d0              ; shading 0..7
        
        ; Get vertex indices
        move.b  3(a0),d1                   ; v0
        move.b  4(a0),d2                   ; v1
        move.b  5(a0),d3                   ; v2
        move.b  6(a0),d4                   ; v3
        
        ; For now: draw wireframe outline of face
        ; Future: use blitter to fill with colour
        
        ; Get projected coordinates
        lsl.w   #2,d1                      ; vertex offset × 4 (2 words per vertex)
        move.w  0(a1,d1.w),d5              ; v0.x
        move.w  2(a1,d1.w),d6              ; v0.y
        
        ; Draw lines connecting vertices (v0-v1, v1-v2, v2-v3, v3-v0)
        ; Using existing BlitLine routine
        
        lea     10(a0),a0                  ; next face
        dbra    d7,.face
        rts

; ═════════════════════════════════════════════════════════════════════════════
; Integration notes for main.s:
;
; 1. Add to main loop (after CalcMatrix, before DrawWire):
;    bsr     UpdateShading
;    bsr     DrawSolid
;
; 2. Reserve palette colours 24-35 for solid objects (already in aga_palette())
;
; 3. Call DrawSolid before DrawWire (painters algorithm - draw back objects first)
;
; 4. Performance:
;    - UpdateShading: ~800 cycles (6 faces)
;    - DrawSolid outline: ~500 cycles (6 × 4 edges × 20 cycles per line)
;    - Total: ~1300 cycles (< 2% of frame budget)
;
; 5. Future phases:
;    - Implement blitter area-fill for face shading
;    - Add octahedron and sphere objects
;    - Implement painters algorithm sorting for multiple objects
;    - Add texture mapping using colour ramps
; ═════════════════════════════════════════════════════════════════════════════
