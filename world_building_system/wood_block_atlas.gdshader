shader_type spatial;
render_mode cull_back, depth_draw_opaque;

uniform sampler2D atlas_texture : source_color, filter_nearest, repeat_enable;
uniform sampler2D church_floor_texture : source_color, filter_nearest, repeat_enable;

const vec2 ATLAS_CELL_SIZE = vec2(1.0 / 3.0, 1.0 / 2.0);

varying vec3 world_normal;
varying float floor_mask;

vec2 _atlas_cell_origin(vec3 n) {
	vec3 an = abs(n);

	if (an.z >= an.x && an.z >= an.y) {
		return n.z > 0.0 ? vec2(0.0, 0.0) : vec2(2.0 * ATLAS_CELL_SIZE.x, 0.0);
	}

	if (an.x >= an.y) {
		return n.x > 0.0 ? vec2(ATLAS_CELL_SIZE.x, 0.0) : vec2(0.0, ATLAS_CELL_SIZE.y);
	}

	return n.y > 0.0 ? vec2(ATLAS_CELL_SIZE.x, ATLAS_CELL_SIZE.y) : vec2(2.0 * ATLAS_CELL_SIZE.x, ATLAS_CELL_SIZE.y);
}

void vertex() {
	world_normal = normalize(MODEL_NORMAL_MATRIX * NORMAL);
	floor_mask = COLOR.r;
}

void fragment() {
	vec3 n = normalize(world_normal);
	vec2 repeated_uv = fract(UV);
	vec4 texel;
	if (floor_mask > 0.5) {
		// Church floor uses its own 6-face atlas, so pick the same face cell
		// layout as the main block atlas instead of sampling the whole image.
		vec2 cell_origin = _atlas_cell_origin(n);
		vec2 atlas_uv = cell_origin + repeated_uv * ATLAS_CELL_SIZE;
		texel = texture(church_floor_texture, atlas_uv);
	} else {
		vec2 cell_origin = _atlas_cell_origin(n);
		vec2 atlas_uv = cell_origin + repeated_uv * ATLAS_CELL_SIZE;
		texel = texture(atlas_texture, atlas_uv);
	}

	ALBEDO = texel.rgb;
	ROUGHNESS = 1.0;
	SPECULAR = 0.0;
}
