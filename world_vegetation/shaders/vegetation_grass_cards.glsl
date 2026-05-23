#[compute]
#version 450

// Dedicated world vegetation compute target.
// Initial native path builds grass cards on CPU in GDExtension for stability.
// This shader is the matching GPU backend shape: one invocation writes one
// fixed grass card into preallocated output buffers.

layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;

struct GrassCell {
	vec4 local_position_rotation; // xyz = chunk-local origin, w = yaw radians
	vec4 scale_maturity_type_flags; // x = scale, y = maturity, z = type index, w = visible flag
};

layout(set = 0, binding = 0, std430) readonly buffer GrassCells {
	GrassCell cells[];
};

layout(set = 0, binding = 1, std430) readonly buffer TypeColors {
	vec4 colors[];
};

layout(set = 0, binding = 2, std430) writeonly buffer OutVertices {
	vec4 vertices[];
};

layout(set = 0, binding = 3, std430) writeonly buffer OutNormals {
	vec4 normals[];
};

layout(set = 0, binding = 4, std430) writeonly buffer OutUvs {
	vec2 uvs[];
};

layout(set = 0, binding = 5, std430) writeonly buffer OutColors {
	vec4 out_colors[];
};

layout(set = 0, binding = 6, std430) writeonly buffer OutIndices {
	uint indices[];
};

layout(push_constant, std430) uniform Params {
	uint cell_count;
	float half_width;
	float height;
	uint type_count;
} params;

vec4 color_for_cell(uint type_index, float maturity) {
	uint safe_index = min(type_index, max(params.type_count, 1u) - 1u);
	vec4 base = colors[safe_index];
	float maturity_scale = mix(0.72, 1.0, clamp(maturity, 0.0, 1.0));
	return vec4(base.rgb * maturity_scale, base.a);
}

void main() {
	uint cell_index = gl_GlobalInvocationID.x;
	if (cell_index >= params.cell_count) {
		return;
	}

	GrassCell cell = cells[cell_index];
	float visible = cell.scale_maturity_type_flags.w;
	uint vertex_base = cell_index * 4u;
	uint index_base = cell_index * 6u;

	if (visible <= 0.0) {
		for (uint i = 0u; i < 4u; ++i) {
			vertices[vertex_base + i] = vec4(0.0);
			normals[vertex_base + i] = vec4(0.0, 1.0, 0.0, 0.0);
			uvs[vertex_base + i] = vec2(0.0);
			out_colors[vertex_base + i] = vec4(0.0);
		}
		for (uint i = 0u; i < 6u; ++i) {
			indices[index_base + i] = vertex_base;
		}
		return;
	}

	vec3 origin = cell.local_position_rotation.xyz;
	float rotation = cell.local_position_rotation.w;
	float scale = max(cell.scale_maturity_type_flags.x, 0.01);
	float maturity = cell.scale_maturity_type_flags.y;
	uint type_index = uint(max(cell.scale_maturity_type_flags.z, 0.0));
	float width = params.half_width * scale;
	float card_height = params.height * scale;
	vec3 right = vec3(cos(rotation) * width, 0.0, sin(rotation) * width);
	vec3 up = vec3(0.0, card_height, 0.0);
	vec3 normal = normalize(vec3(-right.z, 0.0, right.x));
	vec4 color = color_for_cell(type_index, maturity);

	vertices[vertex_base + 0u] = vec4(origin - right, 1.0);
	vertices[vertex_base + 1u] = vec4(origin + right, 1.0);
	vertices[vertex_base + 2u] = vec4(origin + right + up, 1.0);
	vertices[vertex_base + 3u] = vec4(origin - right + up, 1.0);

	for (uint i = 0u; i < 4u; ++i) {
		normals[vertex_base + i] = vec4(normal, 0.0);
		out_colors[vertex_base + i] = color;
	}

	uvs[vertex_base + 0u] = vec2(0.0, 1.0);
	uvs[vertex_base + 1u] = vec2(1.0, 1.0);
	uvs[vertex_base + 2u] = vec2(1.0, 0.0);
	uvs[vertex_base + 3u] = vec2(0.0, 0.0);

	indices[index_base + 0u] = vertex_base + 0u;
	indices[index_base + 1u] = vertex_base + 1u;
	indices[index_base + 2u] = vertex_base + 2u;
	indices[index_base + 3u] = vertex_base + 0u;
	indices[index_base + 4u] = vertex_base + 2u;
	indices[index_base + 5u] = vertex_base + 3u;
}
