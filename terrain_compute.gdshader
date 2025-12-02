// terrain_compute.gdshader
#[compute]

// This defines how many threads run in a single "work group".
// (8, 8, 1) means 64 threads will work on a 8x8 pixel block of the texture.
layout(local_size_x = 8, local_size_y = 8) in;

// This is our output texture. The 'hint(white)' tells Godot it's a single-channel
// texture we intend to write to.
uniform image2D heightmap : hint(white), filter, repeat;

// Parameters we can pass from our script
uniform float time = 0.0;
uniform vec2 noise_scale = vec2(0.01, 0.01);

// A simple pseudo-random function to create "noise"
float random(vec2 st) {
    return fract(sin(dot(st.xy, vec2(12.9898, 78.233))) * 43758.5453123);
}

// A function to create smooth noise
float noise(vec2 st) {
    vec2 i = floor(st);
    vec2 f = fract(st);

    // Four corners of a square
    float a = random(i);
    float b = random(i + vec2(1.0, 0.0));
    float c = random(i + vec2(0.0, 1.0));
    float d = random(i + vec2(1.0, 1.0));

    // Smooth interpolation
    vec2 u = f * f * (3.0 - 2.0 * f);
    return mix(a, b, u.x) + (c - a) * u.y * (1.0 - u.x) + (d - b) * u.x * u.y;
}

// The main entry point for the compute shader
void main() {
    // 'invocation_id' is the unique ID of this thread.
    // It corresponds to the pixel coordinate in the texture.
    ivec2 coord = ivec2(gl_GlobalInvocationID.xy);

    // We'll combine multiple layers of noise for more interesting terrain
    vec2 uv = vec2(coord) * noise_scale;
    
    float height = 0.0;
    float amplitude = 1.0;
    float frequency = 1.0;

    // Add 4 "octaves" of noise
    for (int i = 0; i < 4; i++) {
        height += noise(uv * frequency) * amplitude;
        amplitude *= 0.5; // Halve amplitude each octave
        frequency *= 2.0; // Double frequency each octave
    }

    // Add some animation over time
    height += sin(time + uv.x * 5.0) * 0.1;

    // Write the final height value to the texture.
    // imageStore is how we write to an image in a compute shader.
    // We store it in the 'r' channel (red), which is the only channel we care about.
    imageStore(heightmap, coord, vec4(height, 0.0, 0.0, 1.0));
}