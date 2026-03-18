shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform bool is_first_person = false;
uniform bool debug_colors = false;
uniform float upper_body_z_clip_scale = 0.82;
uniform vec4 upper_body_bone_group_0 = vec4(-1.0);
uniform vec4 upper_body_bone_group_1 = vec4(-1.0);
uniform vec4 upper_body_bone_group_2 = vec4(-1.0);
uniform vec4 upper_body_bone_group_3 = vec4(-1.0);
uniform vec4 upper_body_bone_group_4 = vec4(-1.0);
uniform vec4 upper_body_bone_group_5 = vec4(-1.0);

uniform vec4 albedo_color : source_color = vec4(1.0);
uniform vec4 debug_tint_color : source_color = vec4(0.2, 0.85, 1.0, 1.0);
uniform sampler2D albedo_texture : source_color, hint_default_white;
uniform sampler2D normal_texture : hint_normal;
uniform sampler2D roughness_texture : hint_default_white;
uniform sampler2D metallic_texture : hint_default_white;
uniform float roughness : hint_range(0.0, 1.0) = 1.0;
uniform float metallic : hint_range(0.0, 1.0) = 0.0;
uniform float normal_scale : hint_range(-16.0, 16.0) = 1.0;

varying float v_upper_mask;

bool _matches_upper_body_bone(float bone_index) {
	return bone_index == upper_body_bone_group_0.x || bone_index == upper_body_bone_group_0.y || bone_index == upper_body_bone_group_0.z || bone_index == upper_body_bone_group_0.w
		|| bone_index == upper_body_bone_group_1.x || bone_index == upper_body_bone_group_1.y || bone_index == upper_body_bone_group_1.z || bone_index == upper_body_bone_group_1.w
		|| bone_index == upper_body_bone_group_2.x || bone_index == upper_body_bone_group_2.y || bone_index == upper_body_bone_group_2.z || bone_index == upper_body_bone_group_2.w
		|| bone_index == upper_body_bone_group_3.x || bone_index == upper_body_bone_group_3.y || bone_index == upper_body_bone_group_3.z || bone_index == upper_body_bone_group_3.w
		|| bone_index == upper_body_bone_group_4.x || bone_index == upper_body_bone_group_4.y || bone_index == upper_body_bone_group_4.z || bone_index == upper_body_bone_group_4.w
		|| bone_index == upper_body_bone_group_5.x || bone_index == upper_body_bone_group_5.y || bone_index == upper_body_bone_group_5.z || bone_index == upper_body_bone_group_5.w;
}

void vertex() {
	v_upper_mask = 0.0;
	if (is_first_person) {
		float upper_influence = 0.0;
		if (BONE_WEIGHTS.x > 0.0001 && _matches_upper_body_bone(float(BONE_INDICES.x))) {
			upper_influence += BONE_WEIGHTS.x;
		}
		if (BONE_WEIGHTS.y > 0.0001 && _matches_upper_body_bone(float(BONE_INDICES.y))) {
			upper_influence += BONE_WEIGHTS.y;
		}
		if (BONE_WEIGHTS.z > 0.0001 && _matches_upper_body_bone(float(BONE_INDICES.z))) {
			upper_influence += BONE_WEIGHTS.z;
		}
		if (BONE_WEIGHTS.w > 0.0001 && _matches_upper_body_bone(float(BONE_INDICES.w))) {
			upper_influence += BONE_WEIGHTS.w;
		}

		v_upper_mask = clamp(upper_influence, 0.0, 1.0);
		Z_CLIP_SCALE = mix(1.0, upper_body_z_clip_scale, v_upper_mask);
	}
}

void fragment() {
	vec4 albedo = texture(albedo_texture, UV) * albedo_color;
	if (debug_colors && is_first_person) {
		vec3 lower_tint = vec3(0.95, 0.25, 0.18);
		vec3 upper_tint = debug_tint_color.rgb;
		albedo.rgb = mix(lower_tint, upper_tint, v_upper_mask);
		EMISSION = mix(lower_tint, upper_tint, v_upper_mask) * 0.12;
	} else {
		EMISSION = vec3(0.0);
	}

	ALBEDO = albedo.rgb;
	ROUGHNESS = texture(roughness_texture, UV).r * roughness;
	METALLIC = texture(metallic_texture, UV).r * metallic;
	NORMAL_MAP = texture(normal_texture, UV).rgb;
	NORMAL_MAP_DEPTH = normal_scale;
}
