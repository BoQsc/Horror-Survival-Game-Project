#ifndef VEGETATION_CHUNK_BUILDER_H
#define VEGETATION_CHUNK_BUILDER_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/color.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/transform3d.hpp>
#include <godot_cpp/variant/vector3.hpp>

namespace godot {

class VegetationChunkBuilder : public RefCounted {
    GDCLASS(VegetationChunkBuilder, RefCounted);

protected:
    static void _bind_methods();

public:
    VegetationChunkBuilder();
    ~VegetationChunkBuilder();

    // Builds fixed-card grass chunk geometry from chunk-local cell records.
    // Returns Godot mesh arrays plus bounds/count telemetry. This is the
    // first native replacement for GDScript PackedArray construction.
    Dictionary build_grass_card_mesh(const Array &cells, const Dictionary &type_colors, float half_width, float height);

    // Builds one chunk surface by duplicating a source GLB/imported mesh for
    // each chunk-local record. This keeps GLBs as the authoring source while
    // moving the expensive transform/array construction out of GDScript.
    Dictionary build_source_mesh_instances(const Array &records, const Array &source_arrays, const Transform3D &source_transform, const Vector3 &chunk_origin, const Dictionary &type_colors, bool rotation_is_turns);

    // Packs RenderingServer MultiMesh transform buffers directly from record
    // dictionaries and computes a tight custom AABB for the whole batch.
    Dictionary build_multimesh_transform_buffer(const Array &records, const Transform3D &source_transform, const AABB &source_bounds, bool rotation_is_turns);
};

}

#endif
