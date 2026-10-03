        include "hardware.i"

SCREEN_W_BYTES  EQU 40
SCREEN_H        EQU 256
PLANE_SIZE      EQU SCREEN_W_BYTES*SCREEN_H
PLANE_LONGS     EQU PLANE_SIZE/4
SCREEN_LONGS    EQU PLANE_LONGS*6   ; 6 planes for 64-colour AGA
CHIPDATA_SIZE   EQU chipdata_end-chipdata_begin
FRAME_SYNC_LINE EQU 300     ; first line below the display window (DIWSTOP = line 300)
SILENCE_WORD    EQU $8080   ; 8 bit Paula silence is unsigned $80, not 0

; Screen layout (lines are screen rows; display line = row + 44).
LOGO_Y          EQU 8       ; 64 line logo band
LOGO_H          EQU 64
MID_Y0          EQU 76      ; stars and wireframe live in rows 76..195
MID_H           EQU 120
MID_CX          EQU 160
MID_CY          EQU 136
SCROLL_Y        EQU 200     ; 16 line scroller strip
SCROLL_H        EQU 16

NBALLS          EQU 8       ; hardware sprite ring
SPR_BYTES       EQU 80      ; per page: header 4 + up to 16 lines of 4 + terminator 4, rounded
SPR_PAGES       EQU NBALLS*3 ; one prebuilt page per sprite and ball size
RING_R          EQU 70
RING_TILT       EQU 40      ; tilt of the ring plane (256 = a full turn)
BALL_NEAR       EQU 285     ; distance below which a ball is drawn big (16 px)
BALL_MID        EQU 325     ; ... medium (12 px) below this, else small (8 px)

FLOOR_H         EQU 34      ; copper-bar floor rows (222..255)
NBARS           EQU 4

; Starfield: NSTARS points with (x, y, z); z runs from ZMAX down to ZMIN and wraps.
NSTARS          EQU 48
STAR_SIZE       EQU 10      ; x.w y.w z.w offset.w mask.b class.b
ZMIN            EQU 32
ZRANGE          EQU 224
ZSPEED          EQU 2
ZMID            EQU 150     ; z <= ZMID: mid distance;  z <= ZNEAR: near
ZNEAR           EQU 80
PROJ_F          EQU 128     ; star projection scale

; Wireframe: a regular icosahedron (12 vertices, 30 edges), 7-bit sine table,
; perspective D/(z+ZOFF).
WIRE_D          EQU 220
WIRE_ZOFF       EQU 300
WIRE_S          EQU 42      ; icosahedron vertices reach (+-42, +-26, 0)
WIRE_SWAY       EQU 64      ; sideways swing, pixels
WIRE_ZOOM       EQU 18      ; breathing, distance units

; Runtime pointer slots. AllocChipMem copies the whole data_c block into chip
; RAM and rewrites every one of these long words to point into the copy, so no
; code may use a chipdata label as an address directly.
ptr_screen   equ reloc_table+0
ptr_logo     equ reloc_table+4
ptr_font     equ reloc_table+8
ptr_silence  equ reloc_table+12
ptr_mod      equ reloc_table+16
ptr_copper   equ reloc_table+20
ptr_cop_bpl1 equ reloc_table+24
ptr_raster   equ reloc_table+28
ptr_wave     equ reloc_table+32
ptr_bars     equ reloc_table+36
ptr_sprites  equ reloc_table+40
ptr_cop_spr  equ reloc_table+44

        include "system.s"

        section data,data
old_dmacon:  dc.w 0
old_intena:  dc.w 0
old_adkcon:  dc.w 0
phase:       dc.w 0
scroll_div:  dc.b 0
glyph_col:   dc.b 0
        even
old_copper:  dc.l 0
old_view:    dc.l 0
gfx_base:    dc.l 0
chip_base:   dc.l 0
scroll_ptr:  dc.l scroll_text
rng_seed:    dc.w 1
r_stilt:     dc.w 0             ; ball ring: sin/cos of the tilt and roll, and the matrix coefficients
r_ctilt:     dc.w 0
r_sroll:     dc.w 0
r_croll:     dc.w 0
r_a:         dc.w 0
r_b:         dc.w 0
r_c:         dc.w 0
r_d:         dc.w 0
r_f:         dc.w 0
ball_zc:     ds.w NBALLS        ; per ball: distance, screen x, screen y
ball_sx:     ds.w NBALLS
ball_sy:     ds.w NBALLS
ball_order:  ds.w NBALLS        ; ball numbers, nearest first
frame_no:    dc.w 0
wire_cx:     dc.w MID_CX
wire_zoff:   dc.w WIRE_ZOFF
wire_front:  dc.w 0             ; index of the wireframe buffer being displayed
ang:         dc.w 0             ; the icosahedron's rotation phase (0..255 = a turn)
sx:          dc.w 0             ; sin/cos of the current object's angles, scaled by 127
cx:          dc.w 0
sy:          dc.w 0
cy:          dc.w 0
sz:          dc.w 0
cz:          dc.w 0
 mat:         ds.w 9             ; 3x3 rotation matrix, scaled by 128
 tcol:        ds.l 9             ; matrix * vertex magnitude, by column
 proj:        ds.w 12*2          ; projected (x, y) of the 12 icosahedron vertices
 stars:       ds.b NSTARS*STAR_SIZE

; The twelve DMA visible labels as link-time addresses. AllocChipMem rewrites
; every long word in place, so ptr_* slots hold runtime chip RAM addresses.
        even
reloc_table:
        dc.l screen,logo_data,font_data,audio_silence,mod_data,copper,cop_bpl1,cop_raster_color
        dc.l cop_wave,cop_bars,sprites,cop_spr
RELOC_COUNT     EQU 12

gfx_name:    dc.b "graphics.library",0
        even

scroll_text:
        dc.b "   UBER CRACKING SERVICE PRESENTS: NEON VECTORS - A TINY 68000 OCS CRACKTRO - 3D WIREFRAME VECTORS - DEPTH STARFIELD - COPPER GRADIENTS - FOUR CHANNEL PAULA MOD - GREETINGS TO EVERYONE STILL MAKING THE OLD MACHINES SING!   ",0
        even

raster_colors:
        dc.w $102,$203,$304,$405,$506,$607,$708,$819
        dc.w $92A,$A3B,$B4C,$C5D,$D6E,$E7F,$D6E,$C5D
        dc.w $B4C,$A3B,$92A,$819,$708,$607,$506,$405
        dc.w $304,$203,$102,$213,$324,$435,$546,$657

; BLTCON1 octant bits and LINE for index (steep*4 + up*2 + left); manual table 6-3.
octants:
        dc.b $11,$15,$19,$1D       ; shallow: right/down, left/down, right/up, left/up
        dc.b $01,$09,$05,$0D       ; steep:   right/down, left/down, right/up, left/up

; Wireframe model: a regular icosahedron (12 vertices, 30 edges). The
; classical (0,+-1,+-phi), (+-1,+-phi,0), (+-phi,0,+-1) set scaled by 42/phi
; and rounded; 24 of the 30 edges have squared length 2696 and 6 have 2704
; (a 0.15% spread - the closest regular integer icosahedron at this scale).
verts:
        dc.w   0,  26,  42
        dc.w   0,  26, -42
        dc.w   0, -26,  42
        dc.w   0, -26, -42
        dc.w  26,  42,   0
        dc.w  26, -42,   0
        dc.w -26,  42,   0
        dc.w -26, -42,   0
        dc.w  42,   0,  26
        dc.w  42,   0, -26
        dc.w -42,   0,  26
        dc.w -42,   0, -26
edges:
        dc.b 0,2,  0,4,  0,6,  0,8,  0,10
        dc.b 1,3,  1,4,  1,6,  1,9,  1,11
        dc.b 2,5,  2,7,  2,8,  2,10
        dc.b 3,5,  3,7,  3,9,  3,11
        dc.b 4,6,  4,8,  4,9
        dc.b 5,7,  5,8,  5,9
        dc.b 6,10, 6,11
        dc.b 7,10, 7,11
        dc.b 8,9
        dc.b 10,11
edges_end:

; (x0, z0) of the ball ring for every angle (tools/gen_tables.py ring_tab).
ring_tab:
        dc.w 69,0,69,1,69,3,69,4,68,6,68,8,68,10,68,12
        dc.w 68,13,67,15,67,16,66,18,66,20,66,21,65,23,64,25
        dc.w 63,26,63,27,62,29,61,31,61,32,60,34,59,35,58,37
        dc.w 57,38,56,39,55,41,54,42,53,44,52,45,51,46,50,48
        dc.w 49,49,48,50,46,51,45,52,44,53,42,54,41,55,39,56
        dc.w 38,57,37,58,35,59,34,60,32,61,31,61,29,62,27,63
        dc.w 26,63,25,64,23,65,21,66,20,66,18,66,16,67,15,67
        dc.w 13,68,12,68,10,68,8,68,6,68,4,69,3,69,1,69
        dc.w 0,69,-2,69,-4,69,-5,69,-7,68,-9,68,-11,68,-13,68
        dc.w -14,68,-16,67,-17,67,-19,66,-21,66,-22,66,-24,65,-26,64
        dc.w -27,63,-28,63,-30,62,-32,61,-33,61,-35,60,-36,59,-38,58
        dc.w -39,57,-40,56,-42,55,-43,54,-45,53,-46,52,-47,51,-49,50
        dc.w -50,49,-51,48,-52,46,-53,45,-54,44,-55,42,-56,41,-57,39
        dc.w -58,38,-59,37,-60,35,-61,34,-62,32,-62,31,-63,29,-64,27
        dc.w -64,26,-65,25,-66,23,-67,21,-67,20,-67,18,-68,16,-68,15
        dc.w -69,13,-69,12,-69,10,-69,8,-69,6,-70,4,-70,3,-70,1
        dc.w -70,0,-70,-2,-70,-4,-70,-5,-69,-7,-69,-9,-69,-11,-69,-13
        dc.w -69,-14,-68,-16,-68,-17,-67,-19,-67,-21,-67,-22,-66,-24,-65,-26
        dc.w -64,-27,-64,-28,-63,-30,-62,-32,-62,-33,-61,-35,-60,-36,-59,-38
        dc.w -58,-39,-57,-40,-56,-42,-55,-43,-54,-45,-53,-46,-52,-47,-51,-49
        dc.w -50,-50,-49,-51,-47,-52,-46,-53,-45,-54,-43,-55,-42,-56,-40,-57
        dc.w -39,-58,-38,-59,-36,-60,-35,-61,-33,-62,-32,-62,-30,-63,-28,-64
        dc.w -27,-64,-26,-65,-24,-66,-22,-67,-21,-67,-19,-67,-17,-68,-16,-68
        dc.w -14,-69,-13,-69,-11,-69,-9,-69,-7,-69,-5,-70,-4,-70,-2,-70
        dc.w 0,-70,1,-70,3,-70,4,-70,6,-69,8,-69,10,-69,12,-69
        dc.w 13,-69,15,-68,16,-68,18,-67,20,-67,21,-67,23,-66,25,-65
        dc.w 26,-64,27,-64,29,-63,31,-62,32,-62,34,-61,35,-60,37,-59
        dc.w 38,-58,39,-57,41,-56,42,-55,44,-54,45,-53,46,-52,48,-51
        dc.w 49,-50,50,-49,51,-47,52,-46,53,-45,54,-43,55,-42,56,-40
        dc.w 57,-39,58,-38,59,-36,60,-35,61,-33,61,-32,62,-30,63,-28
        dc.w 63,-27,64,-26,65,-24,66,-22,66,-21,66,-19,67,-17,67,-16
        dc.w 68,-14,68,-13,68,-11,68,-9,68,-7,69,-5,69,-4,69,-2

; Hardware sprite balls: 16, 12 and 8 line bitmaps (planes A, B per line), tools/gen_tables.py balls.
ball_bitmaps:
        dc.w $700,$7E0,$1F88,$1FF0,$3F84,$3FF8,$7F86,$7FF8
        dc.w $7F86,$7FF8,$7F07,$FFF8,$7E0F,$FFF0,$7C1F,$FFE0
        dc.w $01F,$FFE0,$03F,$FFC0,$80FF,$7F00,$3FE,$7C00
        dc.w $7FFE,$000,$3FFC,$000,$1FF8,$000,$7E0,$000
        dc.w $300,$3C0,$F90,$FE0,$1F88,$1FF0,$1F08,$1FF0
        dc.w $3F1C,$3FE0,$1C1C,$3FE0,$03C,$3FC0,$07C,$3F80
        dc.w $1F8,$1E00,$1FF8,$000,$FF0,$000,$3C0,$000
        dc.w $300,$3C0,$7A0,$7C0,$F30,$FC0,$E30,$FC0
        dc.w $070,$F80,$0F0,$F00,$7E0,$000,$3C0,$000

; Wavy logo values (tools/gen_tables.py wave_tab).
wave_tab:
        dc.w $088,$088,$088,$088,$088,$088,$088,$099,$099,$099,$099,$099,$099,$099,$0AA,$0AA
        dc.w $0AA,$0AA,$0AA,$0AA,$0AA,$0AA,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0CC
        dc.w $0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD
        dc.w $0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD
        dc.w $0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD
        dc.w $0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0DD,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC,$0CC
        dc.w $0CC,$0CC,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0BB,$0AA,$0AA,$0AA,$0AA,$0AA
        dc.w $0AA,$0AA,$0AA,$099,$099,$099,$099,$099,$099,$099,$088,$088,$088,$088,$088,$088
        dc.w $088,$077,$077,$077,$077,$077,$077,$066,$066,$066,$066,$066,$066,$066,$055,$055
        dc.w $055,$055,$055,$055,$055,$055,$044,$044,$044,$044,$044,$044,$044,$044,$044,$033
        dc.w $033,$033,$033,$033,$033,$033,$033,$033,$033,$022,$022,$022,$022,$022,$022,$022
        dc.w $022,$022,$022,$022,$022,$022,$022,$022,$022,$022,$022,$022,$022,$022,$022,$022
        dc.w $022,$022,$022,$022,$022,$022,$022,$022,$022,$022,$022,$022,$022,$022,$022,$022
        dc.w $022,$022,$022,$022,$022,$022,$022,$022,$033,$033,$033,$033,$033,$033,$033,$033
        dc.w $033,$033,$044,$044,$044,$044,$044,$044,$044,$044,$044,$055,$055,$055,$055,$055
        dc.w $055,$055,$055,$066,$066,$066,$066,$066,$066,$066,$077,$077,$077,$077,$077,$077

; Copper-bar floor: the static ramp and the 4 bars x 8 rows of colour (tools/gen_tables.py).
floor_base:
        dc.w $102,$102,$102,$102,$102,$102,$202,$202,$202,$213,$213,$213,$213,$213,$213,$213
        dc.w $213,$313,$313,$313,$313,$313,$313,$313,$313,$324,$324,$324,$424,$424,$424,$424
        dc.w $424,$424
bar_colors:
        dc.w $414,$826,$B29,$F3C,$F3C,$B29,$826,$414
        dc.w $134,$268,$2AC,$3DF,$3DF,$2AC,$268,$134
        dc.w $432,$862,$B92,$FC3,$FC3,$B92,$862,$432
        dc.w $142,$284,$3B6,$4F7,$4F7,$3B6,$284,$142

; Reciprocals that replace divisions in the inner loops (tools/gen_tables.py):
; recip_star[z] = round(PROJ_F*256/z), recip_wire[zc] = round(WIRE_D*256/zc), so
; screen offset = (coordinate * recip) >> 8. One MULS is cheaper than one DIVS.
recip_star:
        dc.w 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        dc.w 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        dc.w 1024,993,964,936,910,886,862,840,819,799,780,762,745,728,712,697
        dc.w 683,669,655,643,630,618,607,596,585,575,565,555,546,537,529,520
        dc.w 512,504,496,489,482,475,468,462,455,449,443,437,431,426,420,415
        dc.w 410,405,400,395,390,386,381,377,372,368,364,360,356,352,349,345
        dc.w 341,338,334,331,328,324,321,318,315,312,309,306,303,301,298,295
        dc.w 293,290,287,285,282,280,278,275,273,271,269,266,264,262,260,258
        dc.w 256,254,252,250,248,246,245,243,241,239,237,236,234,232,231,229
        dc.w 228,226,224,223,221,220,218,217,216,214,213,211,210,209,207,206
        dc.w 205,204,202,201,200,199,197,196,195,194,193,192,191,189,188,187
        dc.w 186,185,184,183,182,181,180,179,178,177,176,175,174,173,172,172
        dc.w 171,170,169,168,167,166,165,165,164,163,162,161,161,160,159,158
        dc.w 158,157,156,155,155,154,153,152,152,151,150,150,149,148,148,147
        dc.w 146,146,145,144,144,143,142,142,141,141,140,139,139,138,138,137
        dc.w 137,136,135,135,134,134,133,133,132,132,131,131,130,130,129,129
recip_wire:
        dc.w 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        dc.w 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        dc.w 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        dc.w 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        dc.w 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        dc.w 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        dc.w 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        dc.w 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        dc.w 0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0
        dc.w 0,0,0,0,0,0,375,373,371,368,366,363,361,359,356,354
        dc.w 352,350,348,346,343,341,339,337,335,333,331,329,327,326,324,322
        dc.w 320,318,316,315,313,311,309,308,306,304,303,301,300,298,296,295
        dc.w 293,292,290,289,287,286,284,283,282,280,279,277,276,275,273,272
        dc.w 271,269,268,267,266,264,263,262,261,260,258,257,256,255,254,253
        dc.w 251,250,249,248,247,246,245,244,243,242,241,240,239,238,237,236
        dc.w 235,234,233,232,231,230,229,228,227,226,225,224,223,223,222,221
        dc.w 220,219,218,217,217,216,215,214,213,213,212,211,210,209,209,208
        dc.w 207,206,206,205,204,203,203,202,201,200,200,199,198,198,197,196
        dc.w 196,195,194,194,193,192,192,191,190,190,189,188,188,187,186,186
        dc.w 185,185,184,183,183,182,182,181,181,180,179,179,178,178,177,177
        dc.w 176,175,175,174,174,173,173,172,172,171,171,170,170,169,169,168
        dc.w 168,167,167,166,166,165,165,164,164,163,163,162,162,161,161,160
        dc.w 160,160,159,159,158,158,157,157,156,156,156,155,155,154,154,153
        dc.w 153,153,152,152,151,151,151,150,150,149,149,149,148,148,147,147
        dc.w 147,146,146,146,145,145,144,144,144,143,143,143,142,142,142,141
        dc.w 141,140,140,140,139,139,139,138,138,138,137,137,137,136,136,136

; 256 entries, one turn, amplitude 127 (tools/gen_tables.py sintab).
sintab:
        dc.w 0,3,6,9,12,16,19,22,25,28,31,34,37,40,43,46
        dc.w 49,51,54,57,60,63,65,68,71,73,76,78,81,83,85,88
        dc.w 90,92,94,96,98,100,102,104,106,107,109,111,112,113,115,116
        dc.w 117,118,120,121,122,122,123,124,125,125,126,126,126,127,127,127
        dc.w 127,127,127,127,126,126,126,125,125,124,123,122,122,121,120,118
        dc.w 117,116,115,113,112,111,109,107,106,104,102,100,98,96,94,92
        dc.w 90,88,85,83,81,78,76,73,71,68,65,63,60,57,54,51
        dc.w 49,46,43,40,37,34,31,28,25,22,19,16,12,9,6,3
        dc.w 0,-3,-6,-9,-12,-16,-19,-22,-25,-28,-31,-34,-37,-40,-43,-46
        dc.w -49,-51,-54,-57,-60,-63,-65,-68,-71,-73,-76,-78,-81,-83,-85,-88
        dc.w -90,-92,-94,-96,-98,-100,-102,-104,-106,-107,-109,-111,-112,-113,-115,-116
        dc.w -117,-118,-120,-121,-122,-122,-123,-124,-125,-125,-126,-126,-126,-127,-127,-127
        dc.w -127,-127,-127,-127,-126,-126,-126,-125,-125,-124,-123,-122,-122,-121,-120,-118
        dc.w -117,-116,-115,-113,-112,-111,-109,-107,-106,-104,-102,-100,-98,-96,-94,-92
        dc.w -90,-88,-85,-83,-81,-78,-76,-73,-71,-68,-65,-63,-60,-57,-54,-51
        dc.w -49,-46,-43,-40,-37,-34,-31,-28,-25,-22,-19,-16,-12,-9,-6,-3
        even

; ---------------------------------------------------------------------------
; All DMA visible payloads. The block is copied into freshly allocated chip
; RAM at run time, so the loader may place it anywhere without breaking the
; Copper, the bitplanes, the Paula samples or the silent terminal word.
;
; Copper WAIT is a two word instruction: word one is the beam position with
; bit0 set, word two is the comparison mask with bit0 clear and bit15 set for
; blitter finished. $xx01,$FFFE therefore waits for vertical position $xx with
; every vertical and horizontal bit compared, and $FFFF,$FFFE never matches,
; which parks the list until the next vertical blank reloads COP1LC.
; ---------------------------------------------------------------------------