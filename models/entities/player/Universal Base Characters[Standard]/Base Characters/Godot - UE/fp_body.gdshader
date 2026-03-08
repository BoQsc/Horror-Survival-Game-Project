shader_type spatial;
render_mode blend_mix, depth_draw_opaque, cull_back, diffuse_burley, specular_schlick_ggx;

uniform bool  is_first_person = false;
uniform float neck_cutoff_y   : hint_range(0.0, 3.0) = 1.55;

// All standard PBR inputs
uniform vec4      albedo_color        : source_color = vec4(1.0);
uniform sampler2D albedo_texture      : source_color, hint_default_white;
uniform sampler2D normal_texture      : hint_normal;
uniform sampler2D roughness_texture   : hint_default_white;
uniform sampler2D metallic_texture    : hint_default_white;
uniform float     roughness           : hint_range(0.0, 1.0) = 1.0;
uniform float     metallic            : hint_range(0.0, 1.0) = 0.0;
uniform float     normal_scale        : hint_range(-16.0, 16.0) = 1.0;

varying float v_local_y;

void vertex() {
	v_local_y = VERTEX.y;
	if (is_first_person && VERTEX.y > neck_cutoff_y) {
		POSITION = vec4(2.0, 2.0, 2.0, 1.0);
	}
}

void fragment() {
	if (is_first_person && v_local_y > neck_cutoff_y) {
		discard;
	}
	vec4 albedo = texture(albedo_texture, UV) * albedo_color;
	ALBEDO      = albedo.rgb;
	ALPHA       = albedo.a;
	ROUGHNESS   = texture(roughness_texture, UV).r * roughness;
	METALLIC    = texture(metallic_texture, UV).r * metallic;
	vec3 n      = texture(normal_texture, UV).rgb;
	NORMAL_MAP       = n;
	NORMAL_MAP_DEPTH = normal_scale;
}
