# Prefab Building Conventions

This document describes the conventions for creating prefabs in the building system.

## Coordinate System

- **X**: Left/Right (positive = right)
- **Y**: Up/Down (positive = up)
- **Z**: Front/Back (positive = back, negative = front)

The "front" of a building typically faces **-Z** (toward the camera in default view).

## Block Types

| Type | Shape | Description |
|------|-------|-------------|
| 1 | Cube | Standard 1x1x1 block |
| 2 | Ramp | Sloped surface, rotatable |
| 3 | Sphere | ~~Decorative sphere~~ **(Do not use)** |
| 4 | Stairs | 2-step stair block, rotatable |

## Rotation Meta Values

Rotation is controlled by the `meta` field (0-3). Rotations are **90° clockwise** increments when viewed from above.

### Stairs (Type 4)

The stairs have 2 steps. The "front" (where you start climbing) and "back" (where you exit at top) depend on rotation:

| Meta | Front Faces | Ascends Toward | Use Case |
|------|-------------|----------------|----------|
| 0 | -Z | +Z | Stairs going "into" building |
| 1 | -X | +X | Stairs going right |
| 2 | +Z | -Z | Stairs going "out of" building |
| 3 | +X | -X | Stairs going left |

**Tip**: If you want stairs that go UP as you walk along +Z (deeper into the building), use `meta: 0`.

### Ramps (Type 2)

Ramps slope upward in the direction opposite to where they "face":

| Meta | Low Edge | High Edge | Use Case |
|------|----------|-----------|----------|
| 0 | -Z | +Z | Ramp going up toward +Z |
| 1 | -X | +X | Ramp going up toward +X |
| 2 | +Z | -Z | Ramp going up toward -Z |
| 3 | +X | -X | Ramp going up toward -X |

## Placeable Objects

Objects are placed using `object_id` from the Object Registry. Each object has a defined size:

| ID | Name | Size (X×Y×Z) | Gap Needed |
|----|------|--------------|------------|
| 1 | Cardboard Box | 1×1×1 | 1×1×1 |
| 2 | Long Crate | 2×1×1 | 2×1×1 |
| 3 | Wooden Table | 2×1×1 | Floor space only |
| 4 | Interactive Door | 1×2×1 | **1 wide × 2 high** |
| 5 | Window | 1×1×1 | 1×1×1 |

### Object Rotation

Object rotation uses the same meta convention (0-3 = 0°, 90°, 180°, 270° clockwise).

## CRITICAL: Floor and Surface Heights

**You stand ON TOP of blocks, not inside them!**

| Floor Block Y | Walking Surface Y |
|---------------|-------------------|
| Y=0 | Y=1 |
| Y=4 | Y=5 |
| Y=8 | Y=9 |

A floor block at Y=4 means players walk at height Y=5.

## CRITICAL: Calculating Stair Count

Each stair block provides **1 unit of vertical rise**.

**Formula:**
```
stairs_needed = second_floor_block_Y - ground_floor_block_Y
```

**Example** (Ground floor at Y=0, Second floor at Y=4):
```
Rise needed = 4 - 0 = 4 units
Stairs needed = 4 blocks
```

Place stairs at consecutive Y levels:
- Stair 1: Y=1, Z=start
- Stair 2: Y=2, Z=start+1
- Stair 3: Y=3, Z=start+2
- Stair 4: Y=4, Z=start+3

**Stairwell Openings**: Open holes in the upper floor ONLY where stair blocks physically exist.

**Landing Zone**: The position AFTER the last stair (Z+1) must be **SOLID FLOOR** for landing - NOT a hole!

## Creating Wall Openings

When placing doors or windows, you must leave gaps in the wall blocks.

### CRITICAL: Window Gaps (1×1)

**Windows are 1×1×1. The gap must be ONLY at the window's exact position!**

```
WRONG - Gap at entire vertical column:
  Y=3  [B][B][ ][B][B]   <- Gap at Y=3
  Y=2  [B][B][ ][B][B]   <- Gap at Y=2  ❌ Extra gap!
  Y=1  [B][B][ ][B][B]   <- Gap at Y=1  ❌ Extra gap!
       X=1 X=2 X=3 X=4 X=5

CORRECT - Gap only at window Y level:
  Y=3  [B][B][B][B][B]   <- Solid above window
  Y=2  [B][B][ ][B][B]   <- Gap only at Y=2 (window position) ✓
  Y=1  [B][B][B][B][B]   <- Solid below window
       X=1 X=2 X=3 X=4 X=5
```

Place window object at `[3, 2, Z]` where the gap is.

### Door Gaps (1×2)

Doors are 1 block wide × 2 blocks tall.

```
Door layout:
  Y=3  [B][B][B][B][B]   <- Solid row above door
  Y=2  [B][ ][B][B][B]   <- Gap at X=2 (1 wide, upper)
  Y=1  [B][ ][B][B][B]   <- Gap at X=2 (1 wide, lower)
  Y=0  [B][B][B][B][B]   <- Floor
       X=1 X=2 X=3 X=4 X=5
```

Place door object at `[2, 1, Z]`.

## Prefab JSON Format (v2 - Bracket Notation)

Prefabs use a compact, human-readable bracket notation format.

```json
{
  "name": "my_prefab",
  "version": 2,
  "size": [10, 9, 12],
  "layers": [
    "[1] [1] [1] . . [1] [1] [1]",
    "[1] . . . . . . [1]",
    "[1] . . [4] [4] . . [1]",
    "---",
    "[1] [1] [1] [1:1] . . [1] [1]"
  ],
  "objects": [
    [4, 2, 1, 0, 0, 0.0]
  ]
}
```

### Layer Strings

Each string represents one Z-row. Tokens are space-separated:

| Token | Meaning |
|-------|---------|
| `.` | Empty/air |
| `[type]` | Block with type and meta=0 |
| `[type:meta]` | Block with type and specific meta (rotation) |
| `---` | Y-level separator (next layer up) |

**Reading order**: Layers go Z=0 to Z=max, then `---`, then Y+1.

### Object Arrays

Objects use compact arrays: `[object_id, X, Y, Z, rotation, fractional_y]`

Example: `[4, 2, 1, 0, 0, 0.0]` = Door (id=4) at position (2,1,0), rotation=0

### Fields

| Field | Type | Description |
|-------|------|-------------|
| `version` | int | Must be `2` for bracket notation |
| `size` | [X, Y, Z] | Prefab dimensions |
| `layers` | string[] | Block layout in bracket notation |
| `objects` | array[] | Compact object arrays |

### Converting Old Prefabs

Old v1 prefabs can be converted using:
```bash
python prefabs/convert_prefab.py old_prefab.json
```

## Common Mistakes

1. **Door gap too wide**: Door is 1 block wide, not 2
2. **Window gap too tall**: Window is 1×1×1 - gap only at window's Y, not entire column
3. **Stairs facing wrong way**: Use meta=0 for stairs going INTO building (+Z)
4. **Not enough stairs**: Need N stairs for N-block vertical rise (floor Y difference)
5. **Objects in wrong place**: Object offset must match the gap location exactly
6. **Missing gaps**: Objects don't carve holes - you must omit wall blocks
7. **Forgetting floor surface**: Floor at Y=4 means walking surface at Y=5
8. **Wrong token format**: Use `[type]` or `[type:meta]`, not brackets around coordinates

