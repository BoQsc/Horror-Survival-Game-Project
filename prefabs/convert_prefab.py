#!/usr/bin/env python3
"""
Prefab Format Converter
Converts old prefab format (version 1) to new bracket notation format (version 2)
"""

import json
import sys
from pathlib import Path


def block_to_token(block_type: int, meta: int) -> str:
    """Convert block type and meta to bracket notation token."""
    if meta == 0:
        return f"[{block_type}]"
    else:
        return f"[{block_type}:{meta}]"


def blocks_to_layers(blocks: list, size: list) -> list:
    """Convert blocks array to layer strings."""
    # Build 3D grid [x][y][z]
    grid = [[[None for _ in range(size[2])] for _ in range(size[1])] for _ in range(size[0])]
    
    for block in blocks:
        offset = block["offset"]
        x, y, z = int(offset[0]), int(offset[1]), int(offset[2])
        if 0 <= x < size[0] and 0 <= y < size[1] and 0 <= z < size[2]:
            grid[x][y][z] = {"type": block["type"], "meta": block.get("meta", 0)}
    
    # Convert grid to layer strings
    layers = []
    for y in range(size[1]):
        if y > 0:
            layers.append("---")
        
        for z in range(size[2]):
            row_tokens = []
            for x in range(size[0]):
                cell = grid[x][y][z]
                if cell is None:
                    row_tokens.append(".")
                else:
                    row_tokens.append(block_to_token(cell["type"], cell["meta"]))
            layers.append(" ".join(row_tokens))
    
    return layers


def objects_to_compact(objects: list) -> list:
    """Convert objects to compact array format [id, x, y, z, rot, frac_y]."""
    compact = []
    for obj in objects:
        offset = obj.get("offset", [0, 0, 0])
        compact.append([
            obj.get("object_id", 0),
            offset[0],
            offset[1],
            offset[2],
            obj.get("rotation", 0),
            obj.get("fractional_y", 0.0)
        ])
    return compact


def convert_prefab(input_path: Path) -> dict:
    """Convert a prefab file from v1 to v2 format."""
    with open(input_path, "r", encoding="utf-8") as f:
        data = json.load(f)
    
    # Already v2?
    if data.get("version", 1) >= 2:
        print(f"  Skipping {input_path.name} - already version 2")
        return None
    
    # Get size
    size = data.get("size", [1, 1, 1])
    
    # Convert blocks to layers
    blocks = data.get("blocks", [])
    layers = blocks_to_layers(blocks, size)
    
    # Convert objects to compact format
    objects = data.get("objects", [])
    compact_objects = objects_to_compact(objects)
    
    # Build new format
    new_data = {
        "name": data.get("name", input_path.stem),
        "version": 2,
        "size": size,
        "submerge": data.get("submerge", 1),
        "layers": layers,
        "objects": compact_objects
    }
    
    return new_data


def main():
    if len(sys.argv) < 2:
        print("Usage: python convert_prefab.py <prefab1.json> [prefab2.json] ...")
        print("  Converts old format (v1) prefabs to new bracket notation (v2)")
        sys.exit(1)
    
    for arg in sys.argv[1:]:
        input_path = Path(arg)
        if not input_path.exists():
            print(f"File not found: {input_path}")
            continue
        
        print(f"Converting: {input_path.name}")
        
        new_data = convert_prefab(input_path)
        if new_data is None:
            continue
        
        # Backup original
        backup_path = input_path.with_suffix(".v1.json")
        if not backup_path.exists():
            input_path.rename(backup_path)
            print(f"  Backed up to: {backup_path.name}")
        
        # Write new format
        with open(input_path, "w", encoding="utf-8") as f:
            json.dump(new_data, f, indent="\t")
        
        block_count = len([l for l in new_data["layers"] if l != "---" and "[" in l])
        print(f"  Saved: {input_path.name} ({len(new_data['layers'])} layer lines)")


if __name__ == "__main__":
    main()
