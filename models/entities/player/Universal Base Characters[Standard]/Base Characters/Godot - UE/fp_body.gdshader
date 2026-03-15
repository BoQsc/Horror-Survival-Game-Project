shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_burley, specular_schlick_ggx;

uniform bool  is_first_person = false;
uniform bool  fp_overlay_active = false;
uniform float neck_cutoff_y   : hint_range(0.0, 3.0) = 1.55;
uniform float torso_y         : hint_range(0.0, 3.0) = 0.8; 
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

varying float v_local_y;
varying float v_weight;
varying flat float v_bone;

void vertex() {
	v_local_y = VERTEX.y;
	v_bone = float(BONE_INDICES.x);
	
	// 1. Initial Projection (Standard Camera View)
	vec4 pos = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	
	// 2. Calculate Masking Weight (ALWAYS needed for arm/torso stability)
	float weight = smoothstep(torso_y - 0.5, torso_y - 0.2, VERTEX.y);
	// Bone Exclusion: Strictly isolate legs from the viewmodel effect
	if (min_leg_idx > 0.0 && v_bone >= min_leg_idx && v_bone <= max_leg_idx) {
		weight = 0.0;
	}
	v_weight = weight;
	
	// 3. Viewmodel Overlay effect (Togglable depth pulling)
	if (fp_overlay_active) {
		// Pure visual pulling for the camera. 
		// Since cast_shadow = OFF, we don't need to fear the Sun!
		pos.z = mix(pos.z, pos.w * 0.98, 0.4 * v_weight);
	}

	// 4. Head Hiding (Original height-based logic)
	if (is_first_person) {
		// Hide head from your eyes
		if (VERTEX.y > neck_cutoff_y && v_weight < 0.5) {
			pos = vec4(2.0, 2.0, 2.0, 1.0);
		}
	}
	
	POSITION = pos;
}

void fragment() {
	vec4 albedo_tex = texture(albedo_texture, UV) * albedo_color;
	ALBEDO = albedo_tex.rgb;
	ALPHA = albedo_tex.a;
	
	ROUGHNESS = texture(roughness_texture, UV).r * roughness;
	METALLIC = texture(metallic_texture, UV).r * metallic;
	NORMAL_MAP = texture(normal_texture, UV).rgb;
	NORMAL_MAP_DEPTH = normal_scale;
}
