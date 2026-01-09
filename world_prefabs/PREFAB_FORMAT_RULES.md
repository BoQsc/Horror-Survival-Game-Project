# Prefab Format Rules (v2)

## File Structure (JSON)
```json
{
  "name": "string_id",
  "version": 2,
  "size": [Width_X, Height_Y, Depth_Z],
  "layers": [ ... ],
  "objects": [ ... ]
}
```

## Layers (Block Data)
List of strings. Each string is one Z-row.
- `.`        : Empty (Air)
- `[ID]`     : Block type (default rotation)
- `[ID:ROT]` : Block type with rotation (0-3)
- `---`      : Separator (Moves up to next Y level)

## Objects
Array of: `[ID, X, Y, Z, Rotation, Y_Offset]`
- `Rotation`: 0-3 (90 degree steps)
- `Y_Offset`: Float (fine-tuning vertical pos)

## Key IDs
| ID | Name | Size |
|---|---|---|
| 1 | Cube | 1x1x1 |
| 2 | Ramp | 1x1x1 |
| 4 | Stairs | 1x1x1 |
| 4 (Obj) | Door | 1x2x1 |
| 5 (Obj) | Window | 1x1x1 |

## Coordinate System
- **X+**: Right
- **Y+**: Up
- **Z+**: Back (Entering building = -Z to +Z)
