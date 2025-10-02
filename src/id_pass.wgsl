#import bevy_core_pipeline::fullscreen_vertex_shader::fullscreen_shader_vertex_out
#import bevy_render::view::View

struct ComputedBlurRegion {
    min_x: f32,
    max_x: f32,
    min_y: f32,
    max_y: f32,
    border_radii: vec4<f32>,
    glass_brightness: f32,
    shadow_intensity: f32,
    rim_intensity: f32,
    rim_tightness: f32,
    black_opacity: f32,
    extra_brightness: f32,
    light_intensity: f32,
    displacement_falloff_start: f32,
    displacement_falloff_width: f32,
    specular_intensity: f32,
    reflection_shininess: f32,
    opacity: f32,
    // Padding to match Rust struct layout
    _p1: f32,
    _p2: f32,
    _p3: f32,
}

@group(0) @binding(0) var<uniform> view: View;
@group(1) @binding(0) var<storage, read> blur_regions: array<ComputedBlurRegion>;

const VERTEX_POSITIONS = array<vec2<f32>, 4>(
    vec2<f32>(-1.0, 1.0),
    vec2<f32>(-1.0, -1.0),
    vec2<f32>(1.0, 1.0),
    vec2<f32>(1.0, -1.0),
);

const INDICES = array<u32, 6>(0, 1, 2, 2, 1, 3);

@vertex
fn vertex(
    @builtin(vertex_index) vertex_idx: u32,
    @builtin(instance_index) instance_idx: u32,
) -> @builtin(position) vec4<f32> {
    let region = blur_regions[instance_idx];
    let index = INDICES[vertex_idx];
    let normalized_pos = VERTEX_POSITIONS[index];

    let half_size = vec2(region.max_x - region.min_x, region.max_y - region.min_y) * 0.5;
    let center = vec2(region.min_x, region.min_y) + half_size;

    // Convert from physical pixel coordinates to normalized device coordinates (NDC)
    let screen_pos = center + normalized_pos * half_size;
    let ndc = screen_pos / view.viewport.zw * 2.0 - 1.0;

    // Y is flipped in NDC
    return vec4<f32>(ndc.x, -ndc.y, 0.0, 1.0);
}

@fragment
fn fragment(
    @builtin(instance_index) instance_idx: u32,
) -> @location(0) u32 {
    return instance_idx;
}