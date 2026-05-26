{$ include 'core/full_screen_vertex' $}

{{ struct_definitions }}

@group(0) @binding(0) var t_raw_indirect: texture_2d<f32>;
@group(0) @binding(1) var t_history_indirect: texture_2d<f32>;
@group(0) @binding(2) var t_depth: texture_depth_2d;
@group(0) @binding(3) var t_normal: texture_2d<f32>;
@group(0) @binding(4) var t_history_meta: texture_2d<f32>;
@group(0) @binding(5) var t_velocity: texture_2d<f32>;
@group(0) @binding(6) var s_linear: sampler;
@group(0) @binding(7) var s_point: sampler;
@group(0) @binding(8) var<uniform> u_ssgi: SsgiUniforms;

struct TemporalOutput {
    @location(0) indirect: vec4<f32>,
    @location(1) history_meta: vec4<f32>,
};

struct HistorySample {
    color: vec3<f32>,
    history_len: f32,
    valid: bool,
};

fn unpack_view_normal(packed: vec4<f32>) -> vec3<f32> {
    let raw = packed.xyz * 2.0 - 1.0;
    return normalize(select(vec3<f32>(0.0, 0.0, 1.0), raw, dot(raw, raw) > 1e-5));
}

fn luminance(color: vec3<f32>) -> f32 {
    return dot(max(color, vec3<f32>(0.0)), vec3<f32>(0.2126, 0.7152, 0.0722));
}

fn perceptual_luma(color: vec3<f32>) -> f32 {
    return log2(1.0 + luminance(color));
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
    return u_ssgi.temporal_params.z / max(z, 0.0001);
}

fn get_safe_raw_color(pixel: vec2<i32>, extent: vec2<i32>) -> vec4<f32> {
    let coord = clamp(pixel, vec2<i32>(0, 0), extent - vec2<i32>(1, 1));
    let raw = textureLoad(t_raw_indirect, coord, 0);
    let luma_limit = u_ssgi.temporal_params.y;
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
    history_uv: vec2<f32>,
) -> HistorySample {
    let history_extent = vec2<i32>(textureDimensions(t_history_indirect));
    let max_coord = history_extent - vec2<i32>(1, 1);
    let sample_pos = history_uv * vec2<f32>(history_extent) - vec2<f32>(0.5, 0.5);
    let base_coord = vec2<i32>(floor(sample_pos));
    let frac = fract(sample_pos);

    var color_sum = vec3<f32>(0.0);
    var history_len_sum = 0.0;
    var weight_sum = 0.0;

    for (var y: i32 = 0; y <= 1; y++) {
        for (var x: i32 = 0; x <= 1; x++) {
            let coord = clamp(base_coord + vec2<i32>(x, y), vec2<i32>(0, 0), max_coord);
            let hist_meta = textureLoad(t_history_meta, coord, 0);
            let hist_normal = oct_decode(hist_meta.xy);
            let hist_linear = hist_meta.z;

            if (dot(current_normal, hist_normal) < u_ssgi.reprojection_params.y
                || abs(current_linear - hist_linear) > u_ssgi.reprojection_params.z * max(current_linear, 1.0)) {
                continue;
            }

            let hist_indirect = textureLoad(t_history_indirect, coord, 0);
            if (hist_indirect.a <= 0.0) {
                continue;
            }

            let bilinear_weight_x = select(1.0 - frac.x, frac.x, x == 1);
            let bilinear_weight_y = select(1.0 - frac.y, frac.y, y == 1);
            let weight = bilinear_weight_x * bilinear_weight_y;

            color_sum += hist_indirect.rgb * weight;
            history_len_sum += hist_indirect.a * weight;
            weight_sum += weight;
        }
    }

    if (weight_sum <= 1e-4) {
        return HistorySample(vec3<f32>(0.0), 0.0, false);
    }

    return HistorySample(color_sum / weight_sum, history_len_sum / weight_sum, true);
}

fn resolve_full_uv(half_pixel: vec2<u32>) -> vec2<f32> {
    if (u_ssgi.frame_params.z == 0u) {
        return (vec2<f32>(half_pixel) + vec2<f32>(0.5, 0.5)) * u_ssgi.half_resolution.zw;
    }

    let frame = u_ssgi.frame_params.x;
    let base = vec2<f32>(half_pixel * 2u);
    let offset_x = f32((frame & 1u) ^ ((frame & 2u) >> 1u));
    let offset_y = f32((frame & 2u) >> 1u);
    let offset = vec2<f32>(offset_x + 0.5, offset_y + 0.5);
    return (base + offset) * u_ssgi.full_resolution.zw;
}

@fragment
fn fs_main(in: VertexOutput) -> TemporalOutput {
    var out: TemporalOutput;
    out.indirect = vec4<f32>(0.0);
    out.history_meta = vec4<f32>(0.0);

    let half_pixel = vec2<u32>(in.position.xy);
    let raw_extent = vec2<i32>(textureDimensions(t_raw_indirect));
    let raw_pixel = clamp(vec2<i32>(half_pixel), vec2<i32>(0, 0), raw_extent - vec2<i32>(1, 1));
    let full_uv = resolve_full_uv(half_pixel);
    let current_depth = textureSampleLevel(t_depth, s_point, full_uv, 0u);
    let current_normal_packed = textureSampleLevel(t_normal, s_point, full_uv, 0.0);

    if (current_depth <= 0.0 || current_normal_packed.a < 0.5) {
        return out;
    }

    let current_normal = unpack_view_normal(current_normal_packed);
    let current_linear = linearize_depth(current_depth);
    let camera_cut = (u_ssgi.frame_params.w & 4u) != 0u;

    let current_raw = get_safe_raw_color(raw_pixel, raw_extent);

    var moment1 = vec3<f32>(0.0);
    var moment2 = vec3<f32>(0.0);
    var luma_m1 = 0.0;
    var luma_m2 = 0.0;

    for (var y: i32 = -1; y <= 1; y++) {
        for (var x: i32 = -1; x <= 1; x++) {
            let sample_coord = clamp(raw_pixel + vec2<i32>(x, y), vec2<i32>(0, 0), raw_extent - vec2<i32>(1, 1));
            let sample_value = get_safe_raw_color(sample_coord, raw_extent).rgb;
            moment1 += sample_value;
            moment2 += sample_value * sample_value;
        }
    }

    for (var y: i32 = -2; y <= 2; y++) {
        for (var x: i32 = -2; x <= 2; x++) {
            let sample_coord = clamp(raw_pixel + vec2<i32>(x, y), vec2<i32>(0, 0), raw_extent - vec2<i32>(1, 1));
            let sample_luma = perceptual_luma(get_safe_raw_color(sample_coord, raw_extent).rgb);
            luma_m1 += sample_luma;
            luma_m2 += sample_luma * sample_luma;
        }
    }

    let mean = moment1 / 9.0;
    let variance = max(moment2 / 9.0 - mean * mean, vec3<f32>(0.0));
    let std_dev = sqrt(variance);
    let luma_mean = luma_m1 / 25.0;
    let spatial_variance = max(luma_m2 / 25.0 - luma_mean * luma_mean, 1e-4);

    var indirect = vec4<f32>(current_raw.rgb, max(current_raw.a, 1.0));
    var accepted_history = false;

    if (!camera_cut && (u_ssgi.frame_params.w & 1u) != 0u) {
        let velocity = textureSampleLevel(t_velocity, s_point, full_uv, 0.0).rg;
        let history_uv = in.uv - velocity;

        if (history_uv.x >= 0.0 && history_uv.x <= 1.0 && history_uv.y >= 0.0 && history_uv.y <= 1.0) {
            let history = sample_valid_history(current_normal, current_linear, history_uv);
            if (history.valid) {
                let current_weight = max(u_ssgi.reprojection_params.x, 1.0 / (history.history_len + 1.0));
                let dynamic_gamma = u_ssgi.temporal_params.x * mix(2.0, 1.0, clamp(current_weight, 0.0, 1.0));
                let box_extent = max(std_dev * dynamic_gamma, vec3<f32>(1e-4));
                let clipped_history = clip_towards_aabb_center(history.color, mean, box_extent);
                indirect = vec4<f32>(
                    mix(clipped_history, current_raw.rgb, current_weight),
                    min(history.history_len + 1.0, 32.0)
                );
                accepted_history = true;
            }
        }
    }

    if (!accepted_history) {
        indirect = vec4<f32>(current_raw.rgb, max(current_raw.a, 1.0));
    }

    out.indirect = indirect;
    out.history_meta = vec4<f32>(oct_encode(current_normal), current_linear, spatial_variance);
    return out;
}