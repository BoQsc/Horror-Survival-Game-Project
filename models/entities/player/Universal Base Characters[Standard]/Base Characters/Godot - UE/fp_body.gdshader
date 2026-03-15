shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_burley, specular_schlick_ggx;

// Increase render priority to ensure it renders after environment
// (Not strictly necessary with depth-shifting but helps avoid edge cases)
// NOTE: Setting this on the material in player.tscn instead of here.

uniform bool  is_first_person = false;
uniform float neck_cutoff_y   : hint_range(0.0, 3.0) = 1.55;
uniform float torso_y         : hint_range(0.0, 3.0) = 0.8; // Dynamic anchor from script
uniform float min_leg_idx     = -1.0;
uniform float max_leg_idx     = -1.0;

// All standard PBR inputs
uniform vec4      albedo_color        : source_color = vec4(1.0);
uniform sampler2D albedo_texture      : source_color, hint_default_white;
uniform sampler2D normal_texture      : hint_normal;
uniform sampler2D roughness_texture   : hint_default_white;
uniform sampler2D metallic_texture    : hint_default_white;
uniform float     roughness           : hint_range(0.0, 1.0) = 1.0;
uniform float     metallic            : hint_range(0.0, 1.0) = 0.0;
uniform float     normal_scale        : hint_range(-16.0, 16.0) = 1.0;

// Standard PBR inputs finished
varying float v_local_y;
varying float v_weight;

void vertex() {
	v_local_y = VERTEX.y;
	
	// Default neck-hiding logic
	if (is_first_person && VERTEX.y > neck_cutoff_y) {
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);
	}
	
	// VIEWMODEL OVERLAY: Pull depth closer to camera to avoid clipping
	if (is_first_person) {
		vec4 pos = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
		
		// Mask upwards from the Hips anchor (~0.9m) to cover torso/arms.
		float weight = smoothstep(torso_y - 0.4, torso_y + 0.1, VERTEX.y);
		
		// BONE-RANGE EXCLUSION: Skip overlay if vertex is primary-weighted to the leg range.
		if (min_leg_idx > 0.0 && float(BONE_INDICES.x) >= min_leg_idx && float(BONE_INDICES.x) <= max_leg_idx) {
			weight = 0.0;
		}
		
		v_weight = weight;
		
		// OVERLAY: Push toward the front (Near Plane)
		pos.z = mix(pos.z, pos.w * 0.8, 0.4 * v_weight);
		
		POSITION = pos;
	} else {
		v_weight = 0.0;
	}
}

void fragment() {
	if (is_first_person && v_local_y > neck_cutoff_y) {
		discard;
	}

	vec4 albedo_tex = texture(albedo_texture, UV) * albedo_color;
	ALBEDO = albedo_tex.rgb;
	ALPHA = albedo_tex.a;
	
	ROUGHNESS = texture(roughness_texture, UV).r * roughness;
	METALLIC = texture(metallic_texture, UV).r * metallic;
	NORMAL_MAP = texture(normal_texture, UV).rgb;
	NORMAL_MAP_DEPTH = normal_scale;
}
