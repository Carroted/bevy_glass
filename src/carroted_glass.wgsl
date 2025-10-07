/*
 * This Source Code Form is subject to the terms of the Mozilla Public
 * License, v. 2.0. If a copy of the MPL was not distributed with this
 * file, You can obtain one at https://mozilla.org/MPL/2.0/.
 */
// File-Display-Name: Carroted Glass Shader
// File-Description: A glass panel shader with settings, edge distortion and gaussian blur
// File-Canonical-URL: https://github.com/Carroted/bevy_glass/raw/refs/heads/main/src/shader.wgsl
// SPDX-License-Identifier: MPL-2.0
// SPDX-FileCopyrightText: 2025 Carroted
// Copyright (c) 2025 Carroted

#import bevy_core_pipeline::fullscreen_vertex_shader::FullscreenVertexOutput

#ifdef VERTICAL_PASS
    // Bindings for the VERTICAL pass
    @group(0) @binding(0) var h_pass_texture: texture_2d<f32>;
    @group(0) @binding(1) var original_scene_texture: texture_2d<f32>;
    @group(0) @binding(2) var texture_sampler: sampler;
    @group(0) @binding(3) var<uniform> settings: GpuBlurRegionsSettings;
    @group(0) @binding(4) var<storage, read> blur_regions: array<ComputedBlurRegion>;
#else // HORIZONTAL_PASS
    // Bindings for the HORIZONTAL pass
    @group(0) @binding(0) var screen_texture: texture_2d<f32>;
    @group(0) @binding(1) var texture_sampler: sampler;
    @group(0) @binding(2) var<uniform> settings: GpuBlurRegionsSettings;
    @group(0) @binding(3) var<storage, read> blur_regions: array<ComputedBlurRegion>;
#endif

struct GpuBlurRegionsSettings {
    circle_of_confusion: f32,
    regions_count: u32,
}

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
    blur_only: f32,
}

const BLUR_SIZE: f32 = 50.;
const BLUR_DIRECTIONS: f32 = 20.0;
const BLUR_QUALITY: f32 = 20.0;
const BORDER_SHARPNESS_PX: f32 = 0.75;
const DISPLACEMENT_SCALE: f32 = 0.5;

const BORDER_INSET_PX: f32 = 1.0;

const SHADOW_DISTANCE_PX: f32 = 40.0;

const LIGHT_ADAPTIVITY: f32 = 1.0;
const LIGHT_SOURCE_POS: vec2<f32> = vec2(0.25, -0.1);
const MAX_REGIONS: u32 = 64u;

fn get_normal(p: vec2<f32>, half_size: vec2<f32>, radii: vec4<f32>) -> vec2<f32> {
    let epsilon = vec2(0.001, 0.0);
    let grad_x = sd_rounded_box_per_corner(p + epsilon.xy, half_size, radii) - sd_rounded_box_per_corner(p - epsilon.xy, half_size, radii);
    let grad_y = sd_rounded_box_per_corner(p + epsilon.yx, half_size, radii) - sd_rounded_box_per_corner(p - epsilon.yx, half_size, radii);
    return normalize(vec2(grad_x, grad_y));
}

const PI = 3.14159265;

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
    // let dist = sd_rounded_box_per_corner(p, half_size, radii);
    let dist = sd_rounded_box_per_corner(p, half_size, radii) + px(BORDER_INSET_PX, resolution);
    let box_shape = smoothstep(px(BORDER_SHARPNESS_PX, resolution), 0.0, dist);
    let box_disp = smoothstep(px(displacement_falloff_width, resolution), 0.0, dist + px(displacement_falloff_start, resolution));
    let box_light = box_shape * smoothstep(0.0, px(30.0, resolution), dist + px(10.0, resolution));
    return vec3<f32>(box_shape, box_disp, box_light);
}

fn contrastMatrix(contrast: f32) -> mat4x4<f32> {
    let t = (1.0 - contrast) / 2.0;

    return mat4x4<f32>(
        vec4<f32>(contrast, 0.0, 0.0, 0.0),
        vec4<f32>(0.0, contrast, 0.0, 0.0),
        vec4<f32>(0.0, 0.0, contrast, 0.0),
        vec4<f32>(t, t, t, 1.0),
    );
}

fn brightnessMatrix(brightness: f32) -> mat4x4<f32> {
    return mat4x4<f32>(
        vec4<f32>(1.0, 0.0, 0.0, 0.0),
        vec4<f32>(0.0, 1.0, 0.0, 0.0),
        vec4<f32>(0.0, 0.0, 1.0, 0.0),
        vec4<f32>(brightness, brightness, brightness, 1.0)
    );
}

// Performs a single direction of the separable Gaussian blur kernel.
//
// * `frag_coord` is the screen-space pixel coordinate of the fragment (i.e. the
//   `position` input to the fragment).
//
// * `coc` is the diameter (not the radius) of the circle of confusion for this
//   fragment.
//
// * `frag_offset` is the vector, in screen-space units, from one sample to the
//   next. For a horizontal blur this will be `vec2(1.0, 0.0)`; for a vertical
//   blur this will be `vec2(0.0, 1.0)`.
//
// Returns the resulting color of the fragment.
//
// ATTRIBUTION: This code and comments for this function was originally
// contributed to bevy under the MIT or Apache 2 licenses.
// Modified to take texture and sampler as parameters.
fn gaussian_blur(
    texture: texture_2d<f32>,
    sampler_in: sampler,
    frag_coord: vec4<f32>,
    coc: f32,
    frag_offset: vec2<f32>) -> vec3<f32> {
    // Usually σ (the standard deviation) is half the radius, and the radius is
    // half the CoC. So we multiply by 0.25.
    let sigma = coc * 0.25;

    // 1.5σ is a good, somewhat aggressive default for support—the number of
    // texels on each side of the center that we process.
    let support = i32(ceil(sigma * 1.5));
    let uv = frag_coord.xy / vec2<f32>(textureDimensions(texture));
    let offset = frag_offset / vec2<f32>(textureDimensions(texture));

    // The probability density function of the Gaussian blur is (up to constant factors) `exp(-1 / 2σ² *
    // x²). We precalculate the constant factor here to avoid having to
    // calculate it in the inner loop.
    let exp_factor = -1.0 / (2.0 * sigma * sigma);

    // Accumulate samples on both sides of the current texel. Go two at a time,
    // taking advantage of bilinear filtering.
    var sum = textureSampleLevel(texture, sampler_in, uv, 0.0).rgb;
    var weight_sum = 1.0;
    for (var i = 1; i <= support; i += 2) {
        // This is a well-known trick to reduce the number of needed texture
        // samples by a factor of two. We seek to accumulate two adjacent
        // samples c₀ and c₁ with weights w₀ and w₁ respectively, with a single
        // texture sample at a carefully chosen location. Observe that:
        //
        //     k ⋅ lerp(c₀, c₁, t) = w₀⋅c₀ + w₁⋅c₁
        //
        //                              w₁
        //     if k = w₀ + w₁ and t = ───────
        //                            w₀ + w₁
        //
        // Therefore, if we sample at a distance of t = w₁ / (w₀ + w₁) texels in
        // between the two texel centers and scale by k = w₀ + w₁ afterward, we
        // effectively evaluate w₀⋅c₀ + w₁⋅c₁ with a single texture lookup.
        let w0 = exp(exp_factor * f32(i) * f32(i));
        let w1 = exp(exp_factor * f32(i + 1) * f32(i + 1));
        let uv_offset = offset * (f32(i) + w1 / (w0 + w1));
        let weight = w0 + w1;

        sum += (
            textureSampleLevel(texture, sampler_in, uv + uv_offset, 0.0).rgb +
            textureSampleLevel(texture, sampler_in, uv - uv_offset, 0.0).rgb
        ) * weight;
        weight_sum += weight * 2.0;
    }

    return sum / weight_sum;
}

#ifdef HORIZONTAL_PASS
@fragment
fn horizontal(in: FullscreenVertexOutput) -> @location(0) vec4<f32> {
    let original_color = textureSample(screen_texture, texture_sampler, in.uv);
    var blurred = false;

    // Checks if we're in any blur region
    for (var i = 0u; i < settings.regions_count; i = i + 1u) {
        let region = blur_regions[i];
        if (region.opacity == 0.0) {
            continue; // Skip this region entirely
        }

        // Broad-phase AABB check
        if (in.position.x < region.min_x || in.position.x > region.max_x ||
            in.position.y < region.min_y || in.position.y > region.max_y) {
            continue;
        }

        let center_px = vec2((region.max_x + region.min_x) * 0.5, (region.max_y + region.min_y) * 0.5);
        let half_size_px = vec2(region.max_x - region.min_x, region.max_y - region.min_y) * 0.5;

        let resolution = vec2<f32>(textureDimensions(screen_texture));
        let p_relative = (in.position.xy - center_px) / resolution.y;
        let half_size_st = half_size_px / resolution.y;
        let radii_st = (region.border_radii) / resolution.y;

        // let dist = sd_rounded_box_per_corner(p_relative, half_size_st, radii_st);
        let dist = sd_rounded_box_per_corner(p_relative, half_size_st, radii_st) + px(BORDER_INSET_PX, resolution);
        if (dist <= 0.0) {
            blurred = true;
            break;
        }
    }

    if (blurred) {
        // We're in a region, run the horizontal blur
        let blurred_color = gaussian_blur(screen_texture, texture_sampler, in.position, settings.circle_of_confusion, vec2(1.0, 0.0));
        return vec4<f32>(blurred_color, 1.0);
    } else {
        // Not in any region, pass through original color
        return original_color;
    }
}
#endif // HORIZONTAL_PASS

#ifdef VERTICAL_PASS
@fragment
fn vertical(in: FullscreenVertexOutput) -> @location(0) vec4<f32> {
    let resolution = vec2<f32>(textureDimensions(original_scene_texture));
    let pixel_coord = in.position.xy;
    var final_color = textureSample(original_scene_texture, texture_sampler, in.uv).rgb;
    var final_alpha = 1.0;
    var processed = false;

    for (var i = 0u; i < MAX_REGIONS; i = i + 1u) {
        if (i >= settings.regions_count) {
            break;
        }
        if (processed) { break; }

        let region = blur_regions[i];
        if (region.opacity == 0.0) {
            continue; // Skip this region entirely
        }

        // Broad-phase AABB check
        if (in.position.x < region.min_x || in.position.x > region.max_x ||
            in.position.y < region.min_y || in.position.y > region.max_y) {
            continue;
        }

        let center_px = vec2((region.max_x + region.min_x) * 0.5, (region.max_y + region.min_y) * 0.5);
        let half_size_px = vec2(region.max_x - region.min_x, region.max_y - region.min_y) * 0.5;

        // Mask calculations
        let st = (pixel_coord - 0.5 * resolution) / resolution.y;
        let M = (center_px - 0.5 * resolution) / resolution.y;
        let p_relative = st - M;
        let half_size_st = half_size_px / resolution.y;
        let radii_st = (region.border_radii) / resolution.y;

        let masks = create_masks(p_relative, half_size_st, radii_st, resolution, region.displacement_falloff_width, region.displacement_falloff_start);
        let shape_mask = masks.x;

        if (shape_mask > 0.0) {
            processed = true;

            let bg_color = textureSample(original_scene_texture, texture_sampler, in.uv).rgb;
            var color: vec3<f32>;

            // ADD THIS IF/ELSE LOGIC
            if (region.blur_only > 0.5) {
                // --- BLUR_ONLY MODE ---
                // 1. Get blurred color (no distortion)
                let blurred_color = gaussian_blur(h_pass_texture, texture_sampler, in.position, settings.circle_of_confusion, vec2(0.0, 1.0));
                // 2. Mix it with the background based on the shape's alpha
                color = mix(bg_color, blurred_color, shape_mask);
            } else {
                let disp_mask = masks.y;
                let light_mask = masks.z;

                // UV displacement
                let center_uv = center_px / resolution;
                let uv_from_center = in.uv - center_uv;
                let scale_factor = (1.0 - DISPLACEMENT_SCALE) + DISPLACEMENT_SCALE * smoothstep(0.5, 1.0, disp_mask);
                let uv2 = center_uv + uv_from_center * scale_factor;

                let distorted_position = vec4<f32>(uv2 * resolution, in.position.zw);

                // Mix base color
                let blurred_color = gaussian_blur(h_pass_texture, texture_sampler, distorted_position, settings.circle_of_confusion, vec2(0.0, 1.0));
                color = mix(bg_color, blurred_color, shape_mask);
                color = (brightnessMatrix(region.extra_brightness) * vec4<f32>(color, 1.0)).xyz;
                color = mix(color, vec3(0.0, 0.0, 0.0), region.black_opacity);

                // Apply brightness
                color *= region.glass_brightness;

                let highlight_boost = light_mask * region.light_intensity;
                
                // Calculate both lighting styles
                let additive_result = color + vec3(highlight_boost);
                let multiplicative_result = color * (1.0 + highlight_boost);

                // Blend between the two styles
                color = mix(additive_result, multiplicative_result, LIGHT_ADAPTIVITY);

                let shadow_p = p_relative + vec2(0.0, px(SHADOW_DISTANCE_PX, resolution));
                let shadow_dist = sd_box_sharp(shadow_p, half_size_st);
                color *= 1.0 - region.shadow_intensity * smoothstep(px(80.0, resolution), 0.0, shadow_dist);

                let normal = get_normal(p_relative, half_size_st, radii_st);
                let light_dir = normalize(LIGHT_SOURCE_POS - in.uv);
                let NdotL = max(0.0, dot(normal, light_dir));

                // Sharp, direct specular highlight
                let specular_highlight = pow(NdotL, region.reflection_shininess) * region.specular_intensity;

                // Calculate softer rim light
                // This is brightest on edges perpendicular to the light (grazing angles)
                // (1.0 - NdotL) is highest where the specular is lowest
                let rim_effect = pow(max(0.0, 1.0 - NdotL), region.rim_tightness) * region.rim_intensity;

                // Combine both lighting effects and mask them to the border area
                let total_reflection = (specular_highlight + rim_effect) * light_mask;
                color += vec3(total_reflection);
            }

            final_color = mix(bg_color, color, region.opacity);
            final_alpha = 1.0;
        }
    }

    return vec4<f32>(final_color, final_alpha);
}
#endif // VERTICAL_PASS