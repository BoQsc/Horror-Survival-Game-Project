shader_type spatial;
render_mode blend_mix, depth_draw_always, cull_back, diffuse_burley, specular_schlick_ggx;

// Increase render priority to ensure it renders after environment
// (Not strictly necessary with depth-shifting but helps avoid edge cases)
// NOTE: Setting this on the material in player.tscn instead of here.

uniform bool  fp_hide_head   = false;
uniform bool  fp_overlay_active = false;
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
uniform float head_bone_idx   = -1.0;
uniform float neck_bone_idx   = -1.0;
uniform float     normal_scale        : hint_range(-16.0, 16.0) = 1.0;

// Standard PBR inputs finished
varying float v_local_y;
varying float v_weight;
varying flat float v_bone;

void vertex() {
	v_local_y = VERTEX.y;
	v_bone = float(BONE_INDICES.x);
	
	// 1. Initial Projection
	vec4 pos = PROJECTION_MATRIX * MODELVIEW_MATRIX * vec4(VERTEX, 1.0);
	
	// 2. Viewmodel Overlay (Togglable)
	if (fp_overlay_active) {
		// Masking: Above hips get the treatment.
		float weight = smoothstep(torso_y - 0.5, torso_y - 0.2, VERTEX.y);
		
		// Bone Exclusion: Strictly isolate legs
		if (min_leg_idx > 0.0 && v_bone >= min_leg_idx && v_bone <= max_leg_idx) {
			weight = 0.0;
		}
		
		v_weight = weight;
		
		// Stable depth-pulling: mix current depth with a slightly nearer value based on weight.
		// Pulling toward pos.w * 0.98 ensures it stays just inside the near plane.
		pos.z = mix(pos.z, pos.w * 0.98, 0.4 * v_weight);
	} else {
		v_weight = 0.0;
	}
	
	POSITION = pos;
}

void fragment() {
	// BONE-BASED MASKING: Hide pixels associated with head/neck bones in FP
	if (fp_hide_head) {
		if (abs(v_bone - head_bone_idx) < 0.1 || abs(v_bone - neck_bone_idx) < 0.1) {
			discard;
		}
	}

	vec4 albedo_tex = texture(albedo_texture, UV) * albedo_color;
	ALBEDO = albedo_tex.rgb;
	ALPHA = albedo_tex.a;
	
	ROUGHNESS = texture(roughness_texture, UV).r * roughness;
	METALLIC = texture(metallic_texture, UV).r * metallic;
	NORMAL_MAP = texture(normal_texture, UV).rgb;
	NORMAL_MAP_DEPTH = normal_scale;
}
