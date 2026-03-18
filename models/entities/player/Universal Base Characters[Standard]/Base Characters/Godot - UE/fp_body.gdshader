shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform bool is_first_person = false;
uniform bool debug_colors = false;
uniform float upper_body_mask_threshold = 0.08;
uniform float upper_body_z_clip_scale = 0.82;

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

void vertex() {
	v_upper_mask = 0.0;
	if (is_first_person) {
		v_upper_mask = step(upper_body_mask_threshold, COLOR.r);
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
