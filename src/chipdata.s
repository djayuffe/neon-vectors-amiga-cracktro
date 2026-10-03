        section chipdata,data_c
        cnop 0,4
chipdata_begin:
copper:
        dc.w DIWSTRT,$2C81,DIWSTOP,$2CC1
        dc.w DDFSTRT,$0030,DDFSTOP,$00D0   ; one extra word per line (BPLCON1 scroll), see BPLxMOD
        dc.w BPLCON0,$4200,BPLCON1,$0000,BPLCON2,$0002   ; 4 bitplanes; sprites 4-7 (the far balls) go behind the playfield
        dc.w BPL1MOD,$FFFE,BPL2MOD,$FFFE   ; 21 words fetched, 20 words per line: step back 2 bytes
cop_bpl1:
        dc.w BPL1PTH,0,BPL1PTL,0
        dc.w BPL2PTH,0,BPL2PTL,0
        dc.w BPL3PTH,0,BPL3PTL,0
        dc.w BPL4PTH,0,BPL4PTL,0
; The logo's 16 colour palette (tools/gen_tables.py palette); the Copper reloads a
; different palette below the logo for the stars and objects.
        dc.w COLOR00,$001,COLOR01,$100,COLOR02,$631,COLOR03,$963
        dc.w COLOR04,$FC4,COLOR05,$FE9,COLOR06,$FFC,COLOR07,$FFF
        dc.w COLOR08,$424,COLOR09,$212,COLOR10,$246,COLOR11,$468
        dc.w COLOR12,$6AC,COLOR13,$ADF,COLOR14,$D42,COLOR15,$FFF
; Hardware sprites: eight pointer pairs (the Copper reloads them every frame; PatchSprites
; fills in the runtime addresses once) and the colours of the four sprite pairs.
cop_spr:
        dc.w SPR0PTH,0,SPR0PTL,0
        dc.w SPR1PTH,0,SPR1PTL,0
        dc.w SPR2PTH,0,SPR2PTL,0
        dc.w SPR3PTH,0,SPR3PTL,0
        dc.w SPR4PTH,0,SPR4PTL,0
        dc.w SPR5PTH,0,SPR5PTL,0
        dc.w SPR6PTH,0,SPR6PTL,0
        dc.w SPR7PTH,0,SPR7PTL,0
        dc.w COLOR17,$A50,COLOR18,$FB3,COLOR19,$FFD,COLOR21,$924
        dc.w COLOR22,$E5A,COLOR23,$FCE,COLOR25,$146,COLOR26,$4AF
        dc.w COLOR27,$CEF,COLOR29,$113,COLOR30,$35A,COLOR31,$8BE

; Colour work per raster line (tools/gen_tables.py copper). In the logo band COLOR00 and
; COLOR04 get a gradient on every row; below it the palette is reloaded: COLOR01 is the
; mid-distance star, COLOR04/05 the far and near stars, and any index with bitplane 1 or 3
; set belongs to the 3D objects, so an object always hides the stars behind it.
cop_wave:                                   ; 64 rows, 16 bytes each (BPLCON1 value at +14)
        dc.w $3401,$FFFE,COLOR00,$0002,COLOR04,$0FFF,BPLCON1,$0088
        dc.w $3501,$FFFE,COLOR00,$0002,COLOR04,$0FFF,BPLCON1,$0088
        dc.w $3601,$FFFE,COLOR00,$0002,COLOR04,$0FFF,BPLCON1,$0088
        dc.w $3701,$FFFE,COLOR00,$0002,COLOR04,$0FFF,BPLCON1,$0088
        dc.w $3801,$FFFE,COLOR00,$0002,COLOR04,$0FFF,BPLCON1,$0088
        dc.w $3901,$FFFE,COLOR00,$0002,COLOR04,$0FFE,BPLCON1,$0088
        dc.w $3A01,$FFFE,COLOR00,$0002,COLOR04,$0FFD,BPLCON1,$0088
        dc.w $3B01,$FFFE,COLOR00,$0002,COLOR04,$0FFD,BPLCON1,$0088
        dc.w $3C01,$FFFE,COLOR00,$0002,COLOR04,$0FFC,BPLCON1,$0088
        dc.w $3D01,$FFFE,COLOR00,$0002,COLOR04,$0FEB,BPLCON1,$0088
        dc.w $3E01,$FFFE,COLOR00,$0002,COLOR04,$0FEA,BPLCON1,$0088
        dc.w $3F01,$FFFE,COLOR00,$0002,COLOR04,$0FEA,BPLCON1,$0088
        dc.w $4001,$FFFE,COLOR00,$0002,COLOR04,$0FE9,BPLCON1,$0088
        dc.w $4101,$FFFE,COLOR00,$0002,COLOR04,$0FE8,BPLCON1,$0088
        dc.w $4201,$FFFE,COLOR00,$0002,COLOR04,$0FE8,BPLCON1,$0088
        dc.w $4301,$FFFE,COLOR00,$0002,COLOR04,$0FD7,BPLCON1,$0088
        dc.w $4401,$FFFE,COLOR00,$0103,COLOR04,$0FD7,BPLCON1,$0088
        dc.w $4501,$FFFE,COLOR00,$0103,COLOR04,$0FD6,BPLCON1,$0088
        dc.w $4601,$FFFE,COLOR00,$0103,COLOR04,$0FD6,BPLCON1,$0088
        dc.w $4701,$FFFE,COLOR00,$0103,COLOR04,$0FC5,BPLCON1,$0088
        dc.w $4801,$FFFE,COLOR00,$0103,COLOR04,$0FC5,BPLCON1,$0088
        dc.w $4901,$FFFE,COLOR00,$0103,COLOR04,$0FC4,BPLCON1,$0088
        dc.w $4A01,$FFFE,COLOR00,$0103,COLOR04,$0FC4,BPLCON1,$0088
        dc.w $4B01,$FFFE,COLOR00,$0103,COLOR04,$0FB3,BPLCON1,$0088
        dc.w $4C01,$FFFE,COLOR00,$0103,COLOR04,$0FB3,BPLCON1,$0088
        dc.w $4D01,$FFFE,COLOR00,$0103,COLOR04,$0FB3,BPLCON1,$0088
        dc.w $4E01,$FFFE,COLOR00,$0103,COLOR04,$0FA3,BPLCON1,$0088
        dc.w $4F01,$FFFE,COLOR00,$0103,COLOR04,$0FA3,BPLCON1,$0088
        dc.w $5001,$FFFE,COLOR00,$0103,COLOR04,$0F93,BPLCON1,$0088
        dc.w $5101,$FFFE,COLOR00,$0103,COLOR04,$0F93,BPLCON1,$0088
        dc.w $5201,$FFFE,COLOR00,$0103,COLOR04,$0F93,BPLCON1,$0088
        dc.w $5301,$FFFE,COLOR00,$0103,COLOR04,$0F83,BPLCON1,$0088
        dc.w $5401,$FFFE,COLOR00,$0113,COLOR04,$0E82,BPLCON1,$0088
        dc.w $5501,$FFFE,COLOR00,$0113,COLOR04,$0E82,BPLCON1,$0088
        dc.w $5601,$FFFE,COLOR00,$0113,COLOR04,$0E72,BPLCON1,$0088
        dc.w $5701,$FFFE,COLOR00,$0113,COLOR04,$0E72,BPLCON1,$0088
        dc.w $5801,$FFFE,COLOR00,$0113,COLOR04,$0E62,BPLCON1,$0088
        dc.w $5901,$FFFE,COLOR00,$0113,COLOR04,$0E62,BPLCON1,$0088
        dc.w $5A01,$FFFE,COLOR00,$0113,COLOR04,$0E62,BPLCON1,$0088
        dc.w $5B01,$FFFE,COLOR00,$0113,COLOR04,$0E52,BPLCON1,$0088
        dc.w $5C01,$FFFE,COLOR00,$0113,COLOR04,$0E52,BPLCON1,$0088
        dc.w $5D01,$FFFE,COLOR00,$0113,COLOR04,$0E52,BPLCON1,$0088
        dc.w $5E01,$FFFE,COLOR00,$0113,COLOR04,$0E52,BPLCON1,$0088
        dc.w $5F01,$FFFE,COLOR00,$0113,COLOR04,$0E52,BPLCON1,$0088
        dc.w $6001,$FFFE,COLOR00,$0113,COLOR04,$0E52,BPLCON1,$0088
        dc.w $6101,$FFFE,COLOR00,$0113,COLOR04,$0E52,BPLCON1,$0088
        dc.w $6201,$FFFE,COLOR00,$0113,COLOR04,$0E52,BPLCON1,$0088
        dc.w $6301,$FFFE,COLOR00,$0113,COLOR04,$0E52,BPLCON1,$0088
        dc.w $6401,$FFFE,COLOR00,$0214,COLOR04,$0E52,BPLCON1,$0088
        dc.w $6501,$FFFE,COLOR00,$0214,COLOR04,$0E52,BPLCON1,$0088
        dc.w $6601,$FFFE,COLOR00,$0214,COLOR04,$0E52,BPLCON1,$0088
        dc.w $6701,$FFFE,COLOR00,$0214,COLOR04,$0E52,BPLCON1,$0088
        dc.w $6801,$FFFE,COLOR00,$0214,COLOR04,$0E52,BPLCON1,$0088
        dc.w $6901,$FFFE,COLOR00,$0214,COLOR04,$0E52,BPLCON1,$0088
        dc.w $6A01,$FFFE,COLOR00,$0214,COLOR04,$0E52,BPLCON1,$0088
        dc.w $6B01,$FFFE,COLOR00,$0214,COLOR04,$0E52,BPLCON1,$0088
        dc.w $6C01,$FFFE,COLOR00,$0214,COLOR04,$0E52,BPLCON1,$0088
        dc.w $6D01,$FFFE,COLOR00,$0214,COLOR04,$0E52,BPLCON1,$0088
        dc.w $6E01,$FFFE,COLOR00,$0214,COLOR04,$0E52,BPLCON1,$0088
        dc.w $6F01,$FFFE,COLOR00,$0214,COLOR04,$0E52,BPLCON1,$0088
        dc.w $7001,$FFFE,COLOR00,$0214,COLOR04,$0E52,BPLCON1,$0088
        dc.w $7101,$FFFE,COLOR00,$0214,COLOR04,$0E52,BPLCON1,$0088
        dc.w $7201,$FFFE,COLOR00,$0214,COLOR04,$0E52,BPLCON1,$0088
        dc.w $7301,$FFFE,COLOR00,$0214,COLOR04,$0E52,BPLCON1,$0088
        dc.w $7401,$FFFE                    ; y=72: animated slot, then the wave ends
cop_raster_color:
        dc.w COLOR00,$013                   ; animated by UpdateRaster each frame
        dc.w BPLCON1,$0000
        dc.w COLOR01,$AAD,COLOR02,$3FC,COLOR03,$3FC,COLOR04,$779
        dc.w COLOR05,$FFF,COLOR06,$3FC,COLOR07,$3FC,COLOR08,$39F
        dc.w COLOR09,$39F,COLOR10,$9FF,COLOR11,$9FF,COLOR12,$39F
        dc.w COLOR13,$39F,COLOR14,$9FF,COLOR15,$9FF
        dc.w $7801,$FFFE,COLOR00,$0001,COLOR01,$0AAD
        dc.w $8001,$FFFE,COLOR00,$0001
        dc.w $8801,$FFFE,COLOR00,$0012
        dc.w $9001,$FFFE,COLOR00,$0012
        dc.w $9801,$FFFE,COLOR00,$0013
        dc.w $A001,$FFFE,COLOR00,$0013
        dc.w $A801,$FFFE,COLOR00,$0024
        dc.w $B001,$FFFE,COLOR00,$0024
        dc.w $B801,$FFFE,COLOR00,$0024
        dc.w $C001,$FFFE,COLOR00,$0013
        dc.w $C801,$FFFE,COLOR00,$0013
        dc.w $D001,$FFFE,COLOR00,$0012
        dc.w $D801,$FFFE,COLOR00,$0012
        dc.w $E001,$FFFE,COLOR00,$0001
        dc.w $E801,$FFFE,COLOR00,$0001
        dc.w $F001,$FFFE,COLOR00,$0001
        dc.w $F101,$FFFE,COLOR00,$06CF
        dc.w $F201,$FFFE,COLOR00,$0124
        dc.w $F401,$FFFE,COLOR01,$07EF
        dc.w $F601,$FFFE,COLOR01,$09EF
        dc.w $F801,$FFFE,COLOR01,$0CFF
        dc.w $FA01,$FFFE,COLOR01,$0EFF
        dc.w $FC01,$FFFE,COLOR01,$0EEF
        dc.w $FE01,$FFFE,COLOR01,$0BDF
        dc.w $FFDF,$FFFE                    ; wrap: lines below are 256 + WAIT line
        dc.w $0001,$FFFE,COLOR01,$08CE
        dc.w $0201,$FFFE,COLOR01,$05BE
        dc.w $0601,$FFFE,COLOR00,$06CF
        dc.w $0701,$FFFE,COLOR00,$0001
cop_bars:                                   ; 34 rows of WAIT + COLOR00, 8 bytes each (value at +6)
        dc.w $0A01,$FFFE,COLOR00,$0102
        dc.w $0B01,$FFFE,COLOR00,$0102
        dc.w $0C01,$FFFE,COLOR00,$0102
        dc.w $0D01,$FFFE,COLOR00,$0102
        dc.w $0E01,$FFFE,COLOR00,$0102
        dc.w $0F01,$FFFE,COLOR00,$0102
        dc.w $1001,$FFFE,COLOR00,$0202
        dc.w $1101,$FFFE,COLOR00,$0202
        dc.w $1201,$FFFE,COLOR00,$0202
        dc.w $1301,$FFFE,COLOR00,$0213
        dc.w $1401,$FFFE,COLOR00,$0213
        dc.w $1501,$FFFE,COLOR00,$0213
        dc.w $1601,$FFFE,COLOR00,$0213
        dc.w $1701,$FFFE,COLOR00,$0213
        dc.w $1801,$FFFE,COLOR00,$0213
        dc.w $1901,$FFFE,COLOR00,$0213
        dc.w $1A01,$FFFE,COLOR00,$0213
        dc.w $1B01,$FFFE,COLOR00,$0313
        dc.w $1C01,$FFFE,COLOR00,$0313
        dc.w $1D01,$FFFE,COLOR00,$0313
        dc.w $1E01,$FFFE,COLOR00,$0313
        dc.w $1F01,$FFFE,COLOR00,$0313
        dc.w $2001,$FFFE,COLOR00,$0313
        dc.w $2101,$FFFE,COLOR00,$0313
        dc.w $2201,$FFFE,COLOR00,$0313
        dc.w $2301,$FFFE,COLOR00,$0324
        dc.w $2401,$FFFE,COLOR00,$0324
        dc.w $2501,$FFFE,COLOR00,$0324
        dc.w $2601,$FFFE,COLOR00,$0424
        dc.w $2701,$FFFE,COLOR00,$0424
        dc.w $2801,$FFFE,COLOR00,$0424
        dc.w $2901,$FFFE,COLOR00,$0424
        dc.w $2A01,$FFFE,COLOR00,$0424
        dc.w $2B01,$FFFE,COLOR00,$0424
        dc.w $FFFF,$FFFE

        cnop 0,4
sprites:    ds.b SPR_BYTES*SPR_PAGES    ; prebuilt sprite pages: per sprite one for each ball size
        cnop 0,4
        dc.l 0                      ; the word fetched left of line 0 (planes start 2 bytes early)
screen:     ds.b PLANE_SIZE*6   ; plane 0 | plane 1 buffers 0,1 | plane 2 | plane 3 buffers 0,1
logo_data:  incbin "assets/logo.raw"
font_data:  incbin "assets/font.raw"
audio_silence:
        dc.w SILENCE_WORD           ; Paula's silent terminal word for one-shot samples
        even
mod_data:   incbin "assets/neon.mod"
        even
chipdata_end:
