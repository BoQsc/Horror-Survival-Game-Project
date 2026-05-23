shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;

uniform float alpha_scissor_threshold = 0.35;

void fragment() {
	ALBEDO = COLOR.rgb;
	ALPHA = COLOR.a;
	if (ALPHA < alpha_scissor_threshold) {
		discard;
	}
}
