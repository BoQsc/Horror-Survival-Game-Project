shader_type spatial;
render_mode blend_mix, cull_back, depth_draw_always, depth_prepass_alpha;

// Water colors - darker base to avoid wash-out
uniform vec3 albedo : source_color = vec3(0.08, 0.25, 0.4);         // Teal-blue
uniform vec3 albedo_deep : source_color = vec3(0.02, 0.1, 0.2);     // Deep blue
uniform vec3 albedo_shallow : source_color = vec3(0.15, 0.4, 0.5);  // Lighter shallow
uniform float metallic : hint_range(0.0, 1.0) = 0.4;
uniform float roughness : hint_range(0.0, 1.0) = 0.05;
uniform float beer_factor = 0.25;

// Wave animation
uniform float wave_speed = 0.5;
uniform float wave_scale = 0.008;  // Smaller = larger waves

// Edge effects
uniform float foam_intensity = 0.25;
uniform float foam_threshold = 0.5;
uniform vec3 foam_color : source_color = vec3(0.5, 0.7, 0.8);

uniform sampler2D depth_texture : hint_depth_texture, filter_linear_mipmap;

// Pass world position from vertex shader so it's truly world-space
varying vec3 world_pos;

void vertex() {
	world_pos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	// Lift water slightly to reduce Z-fighting with coplanar terrain
	VERTEX.y += 0.05;
}

// Improved noise - smoother gradient noise (avoids rectangular artifacts)
vec2 hash22(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * vec3(0.1031, 0.1030, 0.0973));
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.xx + p3.yz) * p3.zy);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	
	// Quintic interpolation for smoother results
	vec2 u = f * f * f * (f * (f * 6.0 - 15.0) + 10.0);
	
	// Four corners
	float a = dot(hash22(i) - 0.5, f);
	float b = dot(hash22(i + vec2(1.0, 0.0)) - 0.5, f - vec2(1.0, 0.0));
	float c = dot(hash22(i + vec2(0.0, 1.0)) - 0.5, f - vec2(0.0, 1.0));
	float d = dot(hash22(i + vec2(1.0, 1.0)) - 0.5, f - vec2(1.0, 1.0));
	
	return mix(mix(a, b, u.x), mix(c, d, u.x), u.y) + 0.5;
}

// Fractal Brownian Motion for organic waves
float fbm(vec2 p, float time) {
	float f = 0.0;
	float amp = 0.5;
	// Each octave moves in different directions for organic feel
	f += amp * noise(p * 1.0 + vec2(time * 0.4, time * 0.1)); amp *= 0.5;
	f += amp * noise(p * 2.0 - vec2(time * 0.3, -time * 0.2)); amp *= 0.5;
	f += amp * noise(p * 4.0 + vec2(-time * 0.2, time * 0.15)); amp *= 0.5;
	f += amp * noise(p * 8.0 - vec2(time * 0.1, time * 0.25));
	return f;
}

float fresnel(float amount, vec3 normal, vec3 view) {
	return pow((1.0 - clamp(dot(normalize(normal), normalize(view)), 0.0, 1.0)), amount);
}

void fragment() {
	float time = TIME * wave_speed;
	vec2 uv = world_pos.xz * wave_scale;  // World-space UV, won't move with camera
	
	// Generate smooth wave normal from FBM
	float wave = fbm(uv, time);
	float eps = 0.1;
	float wave_dx = fbm(uv + vec2(eps, 0.0), time) - wave;
	float wave_dz = fbm(uv + vec2(0.0, eps), time) - wave;
	vec3 wave_normal = normalize(vec3(-wave_dx * 1.5, 1.0, -wave_dz * 1.5));
	
	// Blend wave normal with mesh normal
	vec3 final_normal = normalize(mix(NORMAL, wave_normal, 0.35));
	NORMAL = final_normal;
	
	// Depth calculation
	float depth = texture(depth_texture, SCREEN_UV).x;
	vec3 ndc = vec3(SCREEN_UV * 2.0 - 1.0, depth);
	vec4 view_pos = INV_PROJECTION_MATRIX * vec4(ndc, 1.0);
	view_pos.xyz /= view_pos.w;
	float linear_depth = -view_pos.z;
	float linear_surface_depth = -VERTEX.z;
	float depth_diff = max(linear_depth - linear_surface_depth, 0.0);
	
	// Beer's Law - depth absorption
	float depth_alpha = clamp(1.0 - exp(-depth_diff * beer_factor), 0.0, 1.0);
	
	// Three-way color blend: shallow -> mid -> deep
	vec3 color_blend = mix(albedo_shallow, albedo, smoothstep(0.0, 0.3, depth_alpha));
	color_blend = mix(color_blend, albedo_deep, smoothstep(0.4, 1.0, depth_alpha));
	
	// Subtle shimmer from wave
	float shimmer = wave * 0.08;
	color_blend += shimmer * vec3(0.08, 0.12, 0.15);
	
	// Foam at shallow edges - blue-tinted
	float foam = 0.0;
	if (depth_diff < foam_threshold && depth_diff > 0.0) {
		foam = (1.0 - depth_diff / foam_threshold) * foam_intensity;
		foam *= (0.6 + wave * 0.4);  // Animate foam
	}
	color_blend = mix(color_blend, foam_color, foam);
	
	// Fresnel reflection
	float f = fresnel(4.0, final_normal, VIEW);
	vec3 fresnel_color = vec3(0.45, 0.6, 0.7);
	
	ALBEDO = color_blend + fresnel_color * f * 0.3;
	METALLIC = metallic;
	ROUGHNESS = roughness;
	
	// Alpha: transparent shallow, opaque deep
	ALPHA = clamp(0.35 + depth_alpha * 0.6 + foam * 0.15, 0.0, 0.95);
}
