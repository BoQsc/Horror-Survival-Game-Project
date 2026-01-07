# Interactive Door Setup Tutorial

This tutorial explains how to create an interactive door with proper bone-attached collision that follows the door animation.

## Overview

The door system requires:
1. **Door panel collision** - Attached to skeleton bone, follows animation
2. **Frame collision** - Static, doesn't animate
3. **Script** - Handles interaction (E key) and damage

---

## Step-by-Step Setup

### 1. Create the Scene

1. Create a new scene with `Node3D` as root
2. Rename root to `InteractiveDoor`
3. Add your door GLB as a child, rename to `DoorModel`
4. Select `DoorModel` and enable **"Editable Children"** in the inspector

### 2. Find the Skeleton

Navigate through the GLB hierarchy to find the `Skeleton3D` node that animates the door:

```
DoorModel/
  Sketchfab_model/
    .../
      Door_Rig/
        .../
          Skeleton3D  ← Find this!
```

> **Tip:** Look for nodes named "Rig", "Armature", or "Skeleton"

### 3. Create Door Panel Collision (Bone-Attached)

1. Right-click `Skeleton3D` → Add Child Node → `BoneAttachment3D`
2. In inspector, set **bone_name** to the door bone (e.g., `Door_01`)
3. Right-click `BoneAttachment3D` → Add Child Node → `StaticBody3D`
4. Rename to `DoorCollider`

#### Create the CollisionShape3D:

1. Find the door panel mesh (e.g., `SKM_Door`)
2. Select it → Mesh menu → **Create Trimesh Static Body**
3. This creates a `StaticBody3D` with `CollisionShape3D` inside
4. **Delete** the auto-created `StaticBody3D` 
5. **Move** the `CollisionShape3D` under your `DoorCollider`

#### Position the Collision:

1. Select the `CollisionShape3D`
2. Adjust **Position** and **Rotation** to match the door in closed position
3. Play the open/close animation to verify collision follows correctly

### 4. Create Frame Collision (Static)

1. Find the frame mesh node (e.g., `STM_Frame`)
2. Right-click → Add Child Node → `StaticBody3D`
3. Rename to `FrameCollider`
4. Select frame mesh → Mesh menu → **Create Trimesh Static Body**
5. Move the `CollisionShape3D` under your `FrameCollider`

### 5. Add the Script

1. Select the root `InteractiveDoor` node
2. Attach `interactive_door.gd` script
3. The script will automatically find `DoorCollider` and `FrameCollider`

---

## Final Hierarchy

```
InteractiveDoor (Node3D + interactive_door.gd)
└── DoorModel (GLB instance, editable children)
    └── .../Skeleton3D
        ├── BoneAttachment3D (bone_name = "Door_01")
        │   └── DoorCollider (StaticBody3D)
        │       └── CollisionShape3D
        └── .../STM_Frame
            └── FrameCollider (StaticBody3D)
                └── CollisionShape3D
```

---

## Naming Conventions

| Node Name | Type | Purpose |
|-----------|------|---------|
| `DoorCollider` | StaticBody3D | Door panel collision (bone-attached) |
| `FrameCollider` | StaticBody3D | Door frame collision (static) |

The script finds these by name, so use exact names!

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Can't interact with door | Check `DoorCollider` has `"door"` meta (script sets this) |
| Walk through door | Ensure `CollisionShape3D` is child of `StaticBody3D` |
| Collision doesn't follow animation | Verify `BoneAttachment3D` has correct `bone_name` |
| Collision in wrong position | Adjust `CollisionShape3D` transform in editor |

---

## Animation Requirements

The script expects these animation names:
- `HN_Door_Open` - Door opening animation
- `HN_Door_Close` - Door closing animation

Adjust in `interactive_door.gd` if your animations have different names.
