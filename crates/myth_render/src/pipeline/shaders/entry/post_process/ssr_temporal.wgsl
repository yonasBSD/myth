{$ include 'core/full_screen_vertex' $}

{{ struct_definitions }}

@group(0) @binding(0) var t_raw_reflection: texture_2d<f32>;
@group(0) @binding(1) var t_history_reflection: texture_2d<f32>;
@group(0) @binding(2) var t_depth: texture_depth_2d;
@group(0) @binding(3) var t_normal: texture_2d<f32>;
@group(0) @binding(4) var t_history_meta: texture_2d<f32>;
@group(0) @binding(5) var t_velocity: texture_2d<f32>;
@group(0) @binding(6) var t_material_data: texture_2d<f32>;
@group(0) @binding(7) var s_linear: sampler;
@group(0) @binding(8) var s_point: sampler;
@group(0) @binding(9) var<uniform> u_ssr: SsrUniforms;

struct TemporalOutput {
    @location(0) reflection: vec4<f32>,
    @location(1) history_meta: vec4<f32>,
};

struct HistorySample {
    color: vec3<f32>,
    confidence: f32,
    valid: bool,
};

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

fn sign_not_zero(v: f32) -> f32 {
    return select(-1.0, 1.0, v >= 0.0);
}

fn oct_encode(normal: vec3<f32>) -> vec2<f32> {
    let inv_l1 = 1.0 / max(abs(normal.x) + abs(normal.y) + abs(normal.z), 1e-4);
    var encoded = normal.xy * inv_l1;

    if (normal.z < 0.0) {
        encoded = vec2<f32>(
            (1.0 - abs(encoded.y)) * sign_not_zero(encoded.x),
            (1.0 - abs(encoded.x)) * sign_not_zero(encoded.y)
        );
    }

    return encoded * 0.5 + 0.5;
}

fn oct_decode(encoded: vec2<f32>) -> vec3<f32> {
    let f = encoded * 2.0 - 1.0;
    var normal = vec3<f32>(f.x, f.y, 1.0 - abs(f.x) - abs(f.y));

    if (normal.z < 0.0) {
        let old_xy = normal.xy;
        normal.x = (1.0 - abs(old_xy.y)) * sign_not_zero(old_xy.x);
        normal.y = (1.0 - abs(old_xy.x)) * sign_not_zero(old_xy.y);
    }

    return normalize(normal);
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
    let history_extent = vec2<i32>(textureDimensions(t_history_reflection));
    let full_extent = vec2<i32>(i32(u_ssr.full_resolution.x), i32(u_ssr.full_resolution.y));
    if (all(history_extent == full_extent)) {
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

fn get_safe_raw_reflection(pixel: vec2<i32>, extent: vec2<i32>) -> vec4<f32> {
    let coord = clamp(pixel, vec2<i32>(0, 0), extent - vec2<i32>(1, 1));
    let raw = textureLoad(t_raw_reflection, coord, 0);
    let luma_limit = u_ssr.temporal_params.y;
    let raw_luma = luminance(raw.rgb);
    if (luma_limit <= 0.0 || raw_luma <= luma_limit) {
        return raw;
    }

    return vec4<f32>(raw.rgb * (luma_limit / raw_luma), raw.a);
}

fn clip_towards_aabb_center(
    history_color: vec3<f32>,
    box_center: vec3<f32>,
    box_extent: vec3<f32>,
) -> vec3<f32> {
    let diff = history_color - box_center;
    let safe_extent = max(box_extent, vec3<f32>(1e-4));
    let ratio = max(
        abs(diff.x) / safe_extent.x,
        max(abs(diff.y) / safe_extent.y, abs(diff.z) / safe_extent.z)
    );

    if (ratio > 1.0) {
        return box_center + diff / ratio;
    }

    return history_color;
}

fn sample_valid_history(
    current_normal: vec3<f32>,
    current_linear: f32,
    current_roughness: f32,
    history_uv: vec2<f32>,
) -> HistorySample {
    let history_extent = vec2<i32>(textureDimensions(t_history_reflection));
    let max_coord = history_extent - vec2<i32>(1, 1);
    let sample_pos = history_uv * vec2<f32>(history_extent) - vec2<f32>(0.5, 0.5);
    let base_coord = vec2<i32>(floor(sample_pos));
    let frac = fract(sample_pos);

    var color_sum = vec3<f32>(0.0);
    var confidence_sum = 0.0;
    var weight_sum = 0.0;

    for (var y: i32 = 0; y <= 1; y++) {
        for (var x: i32 = 0; x <= 1; x++) {
            let coord = clamp(base_coord + vec2<i32>(x, y), vec2<i32>(0, 0), max_coord);
            let hist_meta = textureLoad(t_history_meta, coord, 0);
            let hist_normal = oct_decode(hist_meta.xy);
            let hist_linear = hist_meta.z;
            let hist_roughness = hist_meta.w;

            if (dot(current_normal, hist_normal) < u_ssr.reprojection_params.y
                || abs(current_linear - hist_linear)
                    > u_ssr.reprojection_params.z * max(current_linear, 1.0)
                || abs(current_roughness - hist_roughness) > u_ssr.reprojection_params.w) {
                continue;
            }

            let hist_reflection = textureLoad(t_history_reflection, coord, 0);
            if (hist_reflection.a <= 1e-4) {
                continue;
            }

            let bilinear_weight_x = select(1.0 - frac.x, frac.x, x == 1);
            let bilinear_weight_y = select(1.0 - frac.y, frac.y, y == 1);
            let weight = bilinear_weight_x * bilinear_weight_y;

            color_sum += hist_reflection.rgb * weight;
            confidence_sum += hist_reflection.a * weight;
            weight_sum += weight;
        }
    }

    if (weight_sum <= 1e-4) {
        return HistorySample(vec3<f32>(0.0), 0.0, false);
    }

    return HistorySample(color_sum / weight_sum, confidence_sum / weight_sum, true);
}

@fragment
fn fs_main(in: VertexOutput) -> TemporalOutput {
    var out: TemporalOutput;
    out.reflection = vec4<f32>(0.0);
    out.history_meta = vec4<f32>(0.0);

    let pixel = vec2<i32>(in.position.xy);
    let raw_extent = vec2<i32>(textureDimensions(t_raw_reflection));
    let surface = sample_surface_conservative(in.uv);
    let current_depth = surface.depth;
    let current_normal_packed = surface.normal_packed;
    if (current_depth <= 0.0 || current_normal_packed.a < 0.5) {
        return out;
    }

    let current_material = textureSampleLevel(t_material_data, s_point, in.uv, 0.0);
    let current_roughness = current_material.a;
    let current_normal = unpack_view_normal(current_normal_packed);
    let current_linear = linearize_depth(current_depth);
    out.history_meta = vec4<f32>(oct_encode(current_normal), current_linear, current_roughness);

    if (current_roughness > u_ssr.shading_params.x) {
        return out;
    }

    let current_raw = get_safe_raw_reflection(pixel, raw_extent);

    var moment1 = vec3<f32>(0.0);
    var moment2 = vec3<f32>(0.0);
    for (var y: i32 = -1; y <= 1; y++) {
        for (var x: i32 = -1; x <= 1; x++) {
            let sample_coord = clamp(pixel + vec2<i32>(x, y), vec2<i32>(0, 0), raw_extent - vec2<i32>(1, 1));
            let sample_value = get_safe_raw_reflection(sample_coord, raw_extent).rgb;
            moment1 += sample_value;
            moment2 += sample_value * sample_value;
        }
    }

    let mean = moment1 / 9.0;
    let variance = max(moment2 / 9.0 - mean * mean, vec3<f32>(0.0));
    let std_dev = sqrt(variance);
    let camera_cut = (u_ssr.frame_params.w & 2u) != 0u;

    var reflection = current_raw;
    var accepted_history = false;

    if (!camera_cut && (u_ssr.frame_params.w & 1u) != 0u) {
        let velocity = textureSampleLevel(t_velocity, s_point, in.uv, 0.0).rg;
        let history_uv = in.uv - velocity;

        if (history_uv.x >= 0.0 && history_uv.x <= 1.0 && history_uv.y >= 0.0 && history_uv.y <= 1.0) {
            let history = sample_valid_history(
                current_normal,
                current_linear,
                current_roughness,
                history_uv,
            );
            if (history.valid) {
                let roughness_ratio = clamp(
                    current_roughness / max(u_ssr.shading_params.x, 1e-4),
                    0.0,
                    1.0
                );
                let current_weight = mix(
                    u_ssr.reprojection_params.x,
                    max(u_ssr.reprojection_params.x * 0.45, 0.04),
                    roughness_ratio
                );
                let box_extent = max(std_dev * u_ssr.temporal_params.x, vec3<f32>(1e-4));
                let clipped_history = clip_towards_aabb_center(history.color, mean, box_extent);
                reflection = vec4<f32>(
                    mix(clipped_history, current_raw.rgb, current_weight),
                    mix(history.confidence, current_raw.a, current_weight)
                );
                accepted_history = true;
            }
        }
    }

    if (!accepted_history && current_raw.a <= 1e-4) {
        reflection = vec4<f32>(0.0);
    }

    out.reflection = reflection;
    return out;
}