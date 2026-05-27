{$ include 'core/full_screen_vertex' $}

{{ struct_definitions }}

@group(0) @binding(0) var t_reflection: texture_2d<f32>;
@group(0) @binding(1) var t_depth: texture_depth_2d;
@group(0) @binding(2) var t_normal: texture_2d<f32>;
@group(0) @binding(3) var t_material_data: texture_2d<f32>;
@group(0) @binding(4) var s_linear: sampler;
@group(0) @binding(5) var s_point: sampler;
@group(0) @binding(6) var<uniform> u_ssr: SsrUniforms;

fn saturate(v: f32) -> f32 {
    return clamp(v, 0.0, 1.0);
}

fn luminance(color: vec3<f32>) -> f32 {
    return dot(max(color, vec3<f32>(0.0)), vec3<f32>(0.2126, 0.7152, 0.0722));
}

fn perceptual_luma(color: vec3<f32>) -> f32 {
    return log2(1.0 + luminance(color));
}

fn unpack_view_normal(packed: vec4<f32>) -> vec3<f32> {
    let raw = packed.xyz * 2.0 - 1.0;
    return normalize(select(vec3<f32>(0.0, 0.0, 1.0), raw, dot(raw, raw) > 1e-5));
}

fn linearize_depth(z: f32) -> f32 {
    return u_ssr.temporal_params.z / max(z, 0.0001);
}

struct SurfaceSample {
    depth: f32,
    normal_packed: vec4<f32>,
};

fn sample_surface_nearest(uv: vec2<f32>) -> SurfaceSample {
    return SurfaceSample(
        textureSampleLevel(t_depth, s_point, uv, 0u),
        textureSampleLevel(t_normal, s_point, uv, 0.0)
    );
}

fn sample_surface_conservative(uv: vec2<f32>) -> SurfaceSample {
    let reflection_extent = vec2<i32>(textureDimensions(t_reflection));
    let full_extent = vec2<i32>(i32(u_ssr.full_resolution.x), i32(u_ssr.full_resolution.y));
    if (all(reflection_extent == full_extent)) {
        return sample_surface_nearest(uv);
    }

    let full_extent_f = vec2<f32>(full_extent);
    let full_pixel = uv * full_extent_f - vec2<f32>(0.5, 0.5);
    let base_coord = clamp(
        vec2<i32>(floor(full_pixel)),
        vec2<i32>(0, 0),
        full_extent - vec2<i32>(2, 2)
    );

    var best_depth = -1.0;
    var best_normal = vec4<f32>(0.0);
    for (var y: i32 = 0; y <= 1; y++) {
        for (var x: i32 = 0; x <= 1; x++) {
            let coord = base_coord + vec2<i32>(x, y);
            let depth = textureLoad(t_depth, coord, 0);
            let normal = textureLoad(t_normal, coord, 0);
            if (normal.a < 0.5 || depth <= 0.0) {
                continue;
            }

            if (depth > best_depth) {
                best_depth = depth;
                best_normal = normal;
            }
        }
    }

    if (best_depth <= 0.0) {
        return sample_surface_nearest(uv);
    }

    return SurfaceSample(best_depth, best_normal);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let extent = vec2<i32>(textureDimensions(t_reflection));
    let reflection_inv_extent = 1.0 / vec2<f32>(extent);
    let center_pixel = clamp(vec2<i32>(in.position.xy), vec2<i32>(0, 0), extent - vec2<i32>(1, 1));
    let center = textureLoad(t_reflection, center_pixel, 0);
    if (center.a <= 1e-4) {
        return vec4<f32>(0.0);
    }

    let center_surface = sample_surface_conservative(in.uv);
    let center_depth = center_surface.depth;
    let center_normal_packed = center_surface.normal_packed;
    if (center_depth <= 0.0 || center_normal_packed.a < 0.5) {
        return center;
    }

    let center_material = textureSampleLevel(t_material_data, s_point, in.uv, 0.0);
    let roughness = center_material.a;
    if (roughness > u_ssr.shading_params.x) {
        return vec4<f32>(0.0);
    }

    let blur_factor = clamp(roughness / max(u_ssr.shading_params.x, 1e-4), 0.0, 1.0);
    if (blur_factor <= 0.05) {
        return center;
    }

    let center_linear = linearize_depth(center_depth);
    let center_normal = unpack_view_normal(center_normal_packed);
    let center_luma = perceptual_luma(center.rgb);
    let depth_sigma = max(u_ssr.reprojection_params.z * max(center_linear, 1.0), 1e-3);
    let normal_power = mix(64.0, u_ssr.shading_params.z, blur_factor);
    let luma_phi = max(mix(0.08, u_ssr.shading_params.w, blur_factor), 1e-3);
    let radius = i32(max(u_ssr.denoise_params.x, 1u));

    var color_sum = center.rgb;
    var confidence_sum = center.a;
    var weight_sum = 1.0;

    for (var y: i32 = -1; y <= 1; y++) {
        for (var x: i32 = -1; x <= 1; x++) {
            if (x == 0 && y == 0) {
                continue;
            }

            let sample_pixel = center_pixel + vec2<i32>(x, y) * radius;
            if (sample_pixel.x < 0 || sample_pixel.y < 0 || sample_pixel.x >= extent.x || sample_pixel.y >= extent.y) {
                continue;
            }

            let sample = textureLoad(t_reflection, sample_pixel, 0);
            if (sample.a <= 1e-4) {
                continue;
            }

            let sample_uv = (vec2<f32>(sample_pixel) + vec2<f32>(0.5, 0.5)) * reflection_inv_extent;
            let sample_surface = sample_surface_conservative(sample_uv);
            let sample_depth = sample_surface.depth;
            let sample_normal_packed = sample_surface.normal_packed;
            if (sample_depth <= 0.0 || sample_normal_packed.a < 0.5) {
                continue;
            }

            let sample_linear = linearize_depth(sample_depth);
            let sample_normal = unpack_view_normal(sample_normal_packed);
            let depth_delta = center_linear - sample_linear;
            let depth_weight = exp(-(depth_delta * depth_delta) / (2.0 * depth_sigma * depth_sigma));
            let normal_weight = pow(saturate(dot(center_normal, sample_normal)), normal_power);
            let luma_weight = exp(-abs(center_luma - perceptual_luma(sample.rgb)) / luma_phi);
            let spatial_weight = 1.0 / f32(abs(x) + abs(y) + 1);
            let weight = spatial_weight * depth_weight * normal_weight * luma_weight;

            color_sum += sample.rgb * weight;
            confidence_sum += sample.a * weight;
            weight_sum += weight;
        }
    }

    return vec4<f32>(
        color_sum / max(weight_sum, 1e-4),
        confidence_sum / max(weight_sum, 1e-4)
    );
}