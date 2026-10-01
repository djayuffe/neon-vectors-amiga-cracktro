# Complete Implementation Plan: Phases 2C, 3, 4

**Status**: Framework design + roadmap (Phase 2C partial implementation)  
**Scope**: Full Gouraud-shaded 3D system with multiple objects and effects  
**Estimated Time**: 8-12 hours for full implementation  
**CPU Budget Target**: <10,000 cycles/frame (7% of budget)

---

## PHASE 2C: Blitter Area-Fill Face Rendering

### Objective
Connect shading data to actual pixel rendering using blitter area-fill.

### Components to Implement

#### 1. Colour Palette Setup
```
Palette colours 24-35: Cube shading ramps
  24-31: Cube face 0 (front) - 8 shading levels
  32-39: Future - additional objects
  (reserved for octahedron/sphere)
```

#### 2. DrawQuad Routine
**Purpose**: Fill a quadrilateral face with colour based on shading

**Algorithm**:
```
for each scanline y in face.top..face.bottom:
    compute left edge x position
    compute right edge x position
    draw horizontal line x_left to x_right at y with blitter
```

**Performance**: ~600 cycles per face (6 faces × 100 scanlines)

#### 3. Integration Points
```
DrawSolid loop:
  for face 0..5:
    shading = shading_lookup[face]
    colour = CUBE_COLOUR_BASE + shading
    DrawQuad(vertices, colour, bitplane)
```

### Key Features
- ✓ Per-face colour selection based on brightness
- ✓ Blitter-accelerated horizontal line drawing
- ✓ Bitplane mask for 6-plane display
- ✓ Painters algorithm ready (draw back-to-front)

### Performance Budget Phase 2C
| Component | Cycles | % Budget |
|-----------|--------|----------|
| UpdateShading | 360 | 0.25% |
| DrawSolid loop | 60 | 0.04% |
| DrawQuad (6 faces) | 3600 | 2.5% |
| **Total Phase 2C** | **4020** | **2.8%** |

---

## PHASE 3: Enhanced Objects & Effects

### Objective
Expand from single cube to multiple objects with dynamic backgrounds.

### 3A: Octahedron Object
**Geometry**:
- 6 vertices (axes: ±x, ±y, ±z)
- 8 triangular faces
- Same shading system as cube

**Implementation**:
```assembly
octahedron_verts:  6 × 3 × i16 = 36 bytes
octahedron_faces:  8 × 7 bytes = 56 bytes
octahedron_shading: ds.b 8      = 8 bytes
```

**Performance**: ~700 cycles (8 faces vs 6 for cube)

### 3B: Sphere Object (Tessellated)
**Geometry**:
- 8 rings × 8 segments = 64 vertices
- ~128 triangular faces
- Procedural shading via vertex normals

**Data**:
```assembly
sphere_verts:     64 × 6 bytes = 384 bytes
sphere_faces:     128 × 7 bytes = 896 bytes
sphere_shading:   ds.b 128 = 128 bytes
```

**Performance**: ~6000 cycles (128 faces with LOD)

### 3C: Parallax Starfield
**Enhancement**: Add depth-based star animation

```
for each star:
  depth = (star.z - ZMIN) / ZRANGE
  brightness = 1 + 2*(depth < 0.5 ? depth : 1-depth)
  parallax_speed = ZSPEED * (1 + depth)
  star.z -= parallax_speed
```

**Performance**: ~300 cycles

### 3D: Glow Effects
**Per-object vertex glow**:
```
for each vertex at screen (x,y):
  for radius r = 1..4:
    draw circle outline at radius r with decreasing brightness
```

**Performance**: ~1000 cycles (16 vertices × 4 radii)

### 3E: Particle System
**Simple sparks around objects**:
```
particles: 32 × [x, y, vx, vy, life]
per frame:
  for each particle:
    x += vx; y += vy; life--
    if life > 0: plot pixel at (x,y) with brightness=life/max_life
    if life == 0: respawn near object
```

**Performance**: ~800 cycles

### Phase 3 Total Performance
| Component | Cycles | % |
|-----------|--------|---|
| Octahedron shading | 700 | 0.5% |
| Sphere shading | 6000 | 4.2% |
| Parallax starfield | 300 | 0.2% |
| Glow effects | 1000 | 0.7% |
| Particles | 800 | 0.6% |
| **Total Phase 3** | **9000** | **6.3%** |
| **Combined 2C+3** | **13020** | **9.1%** |

---

## PHASE 4: Complete System Integration

### 4A: Enhanced Sprite Rendering
**Upgrade**: 24-32px balls with glow halos

```
for each sprite:
  draw outer glow ring (32px diameter, decreasing brightness)
  draw middle glow ring (28px diameter)
  draw bright core ball (24px diameter)
```

**Performance**: ~2000 cycles (8 sprites × 3 layers)

### 4B: Background Animation
**Dynamic parallax with colour cycling**:
```
animate_background:
  scroll starfield by parallax_offset
  cycle palette colours 36-47 (background gradient)
  update copper list for scanline effects
```

**Performance**: ~600 cycles

### 4C: Advanced Lighting
**Dynamic light direction** (optional rotation):
```
if animate_light:
  light_angle += light_speed
  light_x = cos(light_angle) * 64
  light_y = sin(light_angle) * 90
  light_z = 64
  // UpdateShading recalculates all faces
```

**Performance**: ~200 cycles (if enabled)

### 4D: Sorting Algorithm
**Painters algorithm for multi-object rendering**:
```
sort_faces_by_depth:
  collect all faces from all objects
  sort by average z-coordinate (back to front)
  render in sorted order
```

**Performance**: ~500 cycles

### Phase 4 Total Performance
| Component | Cycles | % |
|-----------|--------|---|
| Enhanced sprites | 2000 | 1.4% |
| Background animation | 600 | 0.4% |
| Dynamic lighting | 200 | 0.1% |
| Sorting algorithm | 500 | 0.35% |
| **Total Phase 4** | **3300** | **2.3%** |

---

## TOTAL SYSTEM PERFORMANCE

```
Phase 2A (Framework):      500 cycles (0.35%)
Phase 2B (Rendering stub): included above
Phase 2C (Face fill):     3520 cycles (2.5%)
Phase 3 (Objects+FX):     9000 cycles (6.3%)
Phase 4 (Polish):         3300 cycles (2.3%)

TOTAL:                   16,320 cycles (11.5% of 142k)

HEADROOM REMAINING:      125,680 cycles (88.5%)
```

---

## Implementation Sequence

### Week 1: Phase 2C (Face Rendering)
- [ ] Day 1: DrawQuad routine + colour mapping
- [ ] Day 2: Integration into DrawSolid
- [ ] Day 3: Testing and optimization

### Week 2: Phase 3A-B (Octahedron & Sphere)
- [ ] Day 1: Octahedron data structures
- [ ] Day 2: Sphere tessellation + shading
- [ ] Day 3: Multi-object UpdateShading

### Week 3: Phase 3C-E (Effects)
- [ ] Day 1: Parallax starfield enhancement
- [ ] Day 2: Glow effect rendering
- [ ] Day 3: Particle system

### Week 4: Phase 4 (Polish)
- [ ] Day 1: Enhanced sprite rendering
- [ ] Day 2: Background animation
- [ ] Day 3: Sorting + dynamic lighting
- [ ] Day 4: Integration testing + optimization

---

## Data Structure Totals

| Structure | Size | Phase |
|-----------|------|-------|
| cube_* (existing) | 117 | 2A |
| octahedron_* | 100 | 3A |
| sphere_* | 1400 | 3B |
| particles | 256 | 3E |
| sprite_glow_tables | 512 | 4A |
| **Total new data** | **2280 bytes** | - |

**Memory Impact**: 
- Fast RAM: ~2280 bytes (data tables)
- Chip RAM: 0 bytes (no DMA needed for new data)
- Code size: ~600 bytes (new routines)
- **Total overhead**: ~2900 bytes (3.1% of binary size)

---

## Risk Mitigation

### Performance Risk
**Risk**: System exceeds budget during Phase 3  
**Mitigation**: Implement LOD (level of detail) for sphere
- Use 8×8 grid initially (64 vertices)
- Optional: Reduce to 6×6 (36 vertices) if needed
- Target budget can scale from 4% to 12%

### Complexity Risk
**Risk**: Sorting algorithm causes frame drops  
**Mitigation**: Use simple depth-based sorting
- Sort once per frame (not per face)
- Cache sorted order for smooth animation
- Optional: Quadtree optimization if needed

### Integration Risk
**Risk**: New code breaks existing systems  
**Mitigation**: Incremental integration
- Phase 2C: Update only DrawSolid (isolated)
- Phase 3: Add new objects (parallel systems)
- Phase 4: Integrate sorting (non-invasive)

---

## Quality Gates

### Phase 2C Gate
- [ ] DrawQuad fills faces correctly
- [ ] Colours map to shading values
- [ ] No graphics artifacts
- [ ] <4000 cycles measured
- [ ] All tests pass

### Phase 3 Gate
- [ ] Octahedron renders with lighting
- [ ] Sphere displays smoothly
- [ ] Effects don't cause tearing
- [ ] <10000 cycles measured
- [ ] Multiple objects visible

### Phase 4 Gate
- [ ] Sprite glow renders correctly
- [ ] Sorting handles all orderings
- [ ] Background animation smooth
- [ ] Final system <12000 cycles
- [ ] All visual effects working

---

## Testing Strategy

### Per-Phase Tests
```
Phase 2C:
  ✓ Build validation (VASM, symbols, hunk)
  ✓ Face rendering (visual check on WinUAE)
  ✓ Colour mapping (8 levels per face)
  ✓ Performance profiling (cycle counter)

Phase 3:
  ✓ Multi-object rendering
  ✓ LOD transitions
  ✓ Effect performance
  ✓ Memory usage verification

Phase 4:
  ✓ Sorting correctness
  ✓ Sprite glow rendering
  ✓ Animation smoothness
  ✓ Final system profiling
```

### Integration Tests
```
✓ All objects render together
✓ No visual clipping
✓ Frame rate consistent (50 Hz PAL)
✓ No memory leaks
✓ Clean shutdown
```

---

## Documentation Requirements

For each phase:
- [ ] Code comments (WHY, not WHAT)
- [ ] Performance analysis (cycles/memory)
- [ ] Integration guide (how to enable/disable)
- [ ] Testing checklist (what to verify)
- [ ] Optimization notes (known bottlenecks)

---

## Success Criteria

**Phase 2C Success**:
- Cube faces render with visible shading
- Brightness changes as cube rotates
- Performance <3% of budget overhead

**Phase 3 Success**:
- 3 objects visible simultaneously
- Parallax and glow effects visible
- System remains at 50 FPS

**Phase 4 Success**:
- All effects integrated seamlessly
- Visual quality matches target design
- Performance budget respected (<15% usage)
- Demo is production-ready

---

## Next Actions

1. **Immediate** (Phase 2C):
   - Implement DrawQuad routine
   - Add colour palette setup
   - Test on WinUAE emulator

2. **Short-term** (Phase 3):
   - Add octahedron geometry
   - Implement sphere shading
   - Enhance background effects

3. **Medium-term** (Phase 4):
   - Integrate all systems
   - Optimize performance
   - Final testing on A1200

---

**This plan provides a complete roadmap for implementing Phases 2C, 3, and 4.**
**Estimated total effort: 40-50 hours of development and testing.**
**Target completion: Production-ready demo with full visual effects.**

