// src/composite.wgsl

#import bevy_core_pipeline::fullscreen_vertex_shader::FullscreenVertexOutput

const BORDER_SHARPNESS_PX: f32 = 0.75;

fn get_normal(p: vec2<f32>, half_size: vec2<f32>, radii: vec4<f32>) -> vec2<f32> {
    let epsilon = vec2(0.001, 0.0);
    let grad_x = sd_rounded_box_per_corner(p + epsilon.xy, half_size, radii) - sd_rounded_box_per_corner(p - epsilon.xy, half_size, radii);
    let grad_y = sd_rounded_box_per_corner(p + epsilon.yx, half_size, radii) - sd_rounded_box_per_corner(p - epsilon.yx, half_size, radii);
    return normalize(vec2(grad_x, grad_y));
}

fn px(val: f32, resolution: vec2<f32>) -> f32 {
    return val / resolution.y;
}

fn sd_box_sharp(p: vec2<f32>, b: vec2<f32>) -> f32 {
    let d = abs(p) - b;
    return length(max(d, vec2(0.0))) + min(max(d.x, d.y), 0.0);
}

fn sd_rounded_box_per_corner(p: vec2<f32>, size: vec2<f32>, radii: vec4<f32>) -> f32 {
    var r: f32;
    if (p.x > 0.0) {
        if (p.y > 0.0) {
            r = radii.z;
        } else {
            r = radii.y;
        }
    } else {
        if (p.y > 0.0) {
            r = radii.w;
        } else {
            r = radii.x;
        }
    }
    let q = abs(p) - size + r;
    return min(max(q.x, q.y), 0.0) + length(max(q, vec2(0.0))) - r;
}

fn create_masks(p: vec2<f32>, half_size: vec2<f32>, radii: vec4<f32>, resolution: vec2<f32>, displacement_falloff_width: f32, displacement_falloff_start: f32) -> vec3<f32> {
    let dist = sd_rounded_box_per_corner(p, half_size, radii);
    let box_shape = smoothstep(px(BORDER_SHARPNESS_PX, resolution), 0.0, dist);
    let box_disp = smoothstep(px(displacement_falloff_width, resolution), 0.0, dist + px(displacement_falloff_start, resolution));
    let box_light = box_shape * smoothstep(0.0, px(30.0, resolution), dist + px(10.0, resolution));
    return vec3<f32>(box_shape, box_disp, box_light);
}


fn brightnessMatrix(brightness: f32) -> mat4x4<f32> {
    return mat4x4<f32>(
        vec4<f32>(1.0, 0.0, 0.0, 0.0),
        vec4<f32>(0.0, 1.0, 0.0, 0.0),
        vec4<f32>(0.0, 0.0, 1.0, 0.0),
        vec4<f32>(brightness, brightness, brightness, 1.0)
    );
}


// --- Constants (can be adjusted) ---
const DISPLACEMENT_SCALE: f32 = 0.5;
const SHADOW_DISTANCE_PX: f32 = 40.0;
const LIGHT_ADAPTIVITY: f32 = 1.0;
const LIGHT_SOURCE_POS: vec2<f32> = vec2(0.25, -0.1);
const MAX_REGIONS: u32 = 64u;

// --- Bindings and Structs ---
@group(0) @binding(0) var original_texture: texture_2d<f32>;
@group(0) @binding(1) var blurred_texture: texture_2d<f32>;
@group(0) @binding(2) var id_texture: texture_2d<u32>;
@group(0) @binding(3) var texture_sampler: sampler;
@group(0) @binding(4) var<storage, read> blur_regions: array<ComputedBlurRegion>;

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

// Special value indicating no region is present
const NO_REGION_ID: u32 = 4294967295u; // u32::MAX

@fragment
fn fragment(in: FullscreenVertexOutput) -> @location(0) vec4<f32> {
    // Integer textures are sampled with integer texel coordinates
    let texel_coord = vec2<i32>(in.position.xy);
    
    // --- The O(1) Lookup ---
    let region_index = textureLoad(id_texture, texel_coord, 0).r;
    let original_color = textureSample(original_texture, texture_sampler, in.uv);

    // If this pixel is not in any region, return the original color.
    if (region_index == NO_REGION_ID) {
        return original_color;
    }
    
    // --- We are in a blur region! ---
    let resolution = vec2<f32>(textureDimensions(original_texture));
    var color = textureSample(blurred_texture, texture_sampler, in.uv).rgb;

    // Get settings for the specific region found in the ID buffer
    let region = blur_regions[region_index];

    // --- Glass effect logic ---
    let center_px = vec2((region.max_x + region.min_x) * 0.5, (region.max_y + region.min_y) * 0.5);
    let half_size_px = vec2(region.max_x - region.min_x, region.max_y - region.min_y) * 0.5;

    let st = (in.position.xy - 0.5 * resolution) / resolution.y;
    let M = (center_px - 0.5 * resolution) / resolution.y;
    let p_relative = st - M;
    let half_size_st = half_size_px / resolution.y;
    let radii_st = (region.border_radii) / resolution.y;

    let masks = create_masks(p_relative, half_size_st, radii_st, resolution, region.displacement_falloff_width, region.displacement_falloff_start);
    let shape_mask = masks.x;
    let disp_mask = masks.y;
    let light_mask = masks.z;
    
    let center_uv = center_px / resolution;
    let uv_from_center = in.uv - center_uv;
    let scale_factor = (1.0 - DISPLACEMENT_SCALE) + DISPLACEMENT_SCALE * smoothstep(0.5, 1.0, disp_mask);
    let uv2 = center_uv + uv_from_center * scale_factor;
    
    // Combine base color and effects
    color = (brightnessMatrix(region.extra_brightness) * vec4<f32>(color, 1.0)).xyz;
    color = mix(color, vec3(0.0, 0.0, 0.0), region.black_opacity);
    color *= region.glass_brightness;

    // Lighting
    let highlight_boost = light_mask * region.light_intensity;
    let additive_result = color + vec3(highlight_boost);
    let multiplicative_result = color * (1.0 + highlight_boost);
    color = mix(additive_result, multiplicative_result, LIGHT_ADAPTIVITY);

    // Shadow
    let shadow_p = p_relative + vec2(0.0, px(SHADOW_DISTANCE_PX, resolution));
    let shadow_dist = sd_box_sharp(shadow_p, half_size_st);
    color *= 1.0 - region.shadow_intensity * smoothstep(px(80.0, resolution), 0.0, shadow_dist);

    // Reflections
    let normal = get_normal(p_relative, half_size_st, radii_st);
    let light_dir = normalize(LIGHT_SOURCE_POS - in.uv);
    let NdotL = max(0.0, dot(normal, light_dir));
    let specular_highlight = pow(NdotL, region.reflection_shininess) * region.specular_intensity;
    let rim_effect = pow(max(0.0, 1.0 - NdotL), region.rim_tightness) * region.rim_intensity;
    let total_reflection = (specular_highlight + rim_effect) * light_mask;
    color += vec3(total_reflection);

    // --- Final Composite ---
    // Mix the original displaced color with the final glass color based on the shape and opacity.
    let final_mask = shape_mask * region.opacity;
    let final_color = mix(textureSample(original_texture, texture_sampler, uv2).rgb, color, final_mask);

    return vec4<f32>(final_color, 1.0);
}