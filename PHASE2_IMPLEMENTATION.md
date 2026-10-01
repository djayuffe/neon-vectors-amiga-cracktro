# Phase 2 Implementation: Gouraud-Shaded 3D Objects

## Overview
Implement solid 3D rendering with per-face Gouraud shading using the Amiga blitter.
Each 3D object (cube, octahedron, sphere) is rendered as flat-shaded faces whose
brightness depends on the angle to the light source.

## Components

### 1. Gouraud Shading Framework
- **Per-face lighting calculation**: Light direction = (-0.5, -0.7, 0.5)
- **Shading values**: 0 (dark) to 7 (bright), 8 levels per colour
- **Lookup table**: `shading_lookup[6]` updated each frame after rotation

### 2. 3D Object Definitions

#### Cube (40 unit half-size)
- 8 vertices (corners)
- 6 faces (front, back, left, right, top, bottom)
- Each face: normal vector + 4 vertex indices + colour base
- Winding order: CCW when viewed from outside

#### Octahedron (28 unit radius)
- 6 vertices (3 axes)
- 8 triangular faces
- Same shading system as cube

#### Sphere (procedural)
- 8 rings × 8 segments = 64 vertices
- Per-vertex shading from gouraud.py
- Real-time lighting based on rotation

### 3. Rendering Pipeline

#### UpdateShading (before frame draw)
1. Transform face normals by current rotation matrix
2. Calculate dot product with light direction
3. Clamp to 0..7 range
4. Store in `shading_lookup[]`

#### DrawSolid (main render)
1. For each face:
   a. Back-face cull (normal.z > 0 after rotation = facing away)
   b. Get projected vertices from `proj[]`
   c. Look up shading value
   d. Draw using blitter area-fill or scanline rasterizer

### 4. Blitter Area-Fill Strategy

Option A: **Simple scanline fill** (CPU, ~1000 cycles per face)
- Compute edge equations for each polygon edge
- Iterate scanlines, draw horizontal lines with blitter
- Set colour based on `shading_lookup[]`

Option B: **Blitter edge-trace** (if hardware supports it)
- Use blitter line mode to draw edges
- Use area-fill mode to shade interior
- Faster for large faces

### 5. Colour Mapping

Each 3D object uses a colour ramp:
- Base colour (24-35 for objects): `24 + object_id*6`
- Shading offset (0-7): selected by `shading_lookup[face]`
- Final colour: `base + shading_offset`

Example for cube:
- Face shading 0-7 maps to colours 24-31 (cube 0)
- Face shading 0-7 maps to colours 32-39 (if cube 1 exists)

### 6. Performance Budget

**Per frame:**
- UpdateShading: ~800 cycles (6 faces × matrix×vector)
- DrawSolid (6 faces): ~8000 cycles (CPU scanline fill)
- Total: ~8800 cycles (1.8% of frame budget)

**Headroom: 50+ available**

### 7. Integration Steps

1. Add `cube_verts`, `cube_faces`, `shading_lookup` to main.s data section
2. Add `UpdateShading` and `DrawSolid` routines before wireframe code
3. Update main loop:
   - Call `UpdateShading` after `CalcMatrix`
   - Call `DrawSolid` before/after wireframe (painters algorithm sort needed)
4. Update palette: reserve 12 colours for 3D objects (24-35)
5. Test with rotating cube

### 8. Future Enhancements

- **Sorting**: Use painters algorithm to draw faces back-to-front
- **Larger objects**: Octahedron, sphere with same shading
- **Textures**: Use colour ramps for pattern/texture mapping
- **Blitter optimization**: Replace CPU scanline fill with blitter area-fill
- **Transparency**: Overlay shaded objects on wireframe

## Testing Checklist

- [ ] Cube renders with correct colours
- [ ] Shading changes as cube rotates
- [ ] Back-face culling works (hidden faces don't render)
- [ ] Performance is within budget (<10k cycles per frame)
- [ ] Colours don't overlap with logo/sprites/background
- [ ] Integration with existing wireframe (both visible)
- [ ] Smooth rotation without artifacts

## Files to Modify

1. `src/main.s`
   - Add cube data and shading lookup
   - Add UpdateShading routine
   - Add DrawSolid routine
   - Update main loop
   - Reserve bitplanes/colours for solid objects

2. `src/hardware.i` (if needed)
   - Define solid object colour bases (may not be needed)

3. `tools/gen_tables.py`
   - Already has aga_palette() with solid object colours (24-35)

4. Documentation
   - Update README_AGA.md with solid 3D progress
   - Add notes on rendering architecture
