shader_type canvas_item;

// Animated underwater screen effect
// Wavey distortion with color tint - MORE NOTICEABLE values

uniform float distortion_strength : hint_range(0.0, 0.1) = 0.005;  // Barely noticeable
uniform float wave_speed : hint_range(0.5, 5.0) = 2.0;
uniform float wave_frequency : hint_range(2.0, 20.0) = 5.0;  // Lower = larger waves
uniform vec4 tint_color : source_color = vec4(0.02, 0.18, 0.12, 0.45);  // Slightly stronger tint

uniform sampler2D SCREEN_TEXTURE : hint_screen_texture, filter_linear_mipmap;

void fragment() {
    vec2 uv = SCREEN_UV;
    float time = TIME * wave_speed;
    
    // Primary wave - large swooshing motion
    float wave_x = sin(uv.y * wave_frequency + time) * distortion_strength;
    float wave_y = cos(uv.x * wave_frequency * 1.2 + time * 0.7) * distortion_strength * 0.7;
    
    // Secondary wave layer - adds organic feel
    wave_x += sin(uv.y * wave_frequency * 2.5 + time * 1.4) * distortion_strength * 0.35;
    wave_y += cos(uv.x * wave_frequency * 1.8 + time * 1.1) * distortion_strength * 0.25;
    
    vec2 distorted_uv = uv + vec2(wave_x, wave_y);
    
    // Sample screen with distortion
    vec4 screen = texture(SCREEN_TEXTURE, distorted_uv);
    
    // Apply tint - blend toward underwater color
    vec3 tinted = mix(screen.rgb, tint_color.rgb, tint_color.a);
    
    COLOR = vec4(tinted, 1.0);
}
