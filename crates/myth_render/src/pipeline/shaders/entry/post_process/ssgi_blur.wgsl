{$ include 'core/full_screen_vertex' $}

{{ struct_definitions }}

@group(0) @binding(0) var t_indirect: texture_2d<f32>;
@group(0) @binding(1) var t_depth: texture_depth_2d;
@group(0) @binding(2) var t_normal: texture_2d<f32>;
@group(0) @binding(3) var s_linear: sampler;
@group(0) @binding(4) var s_point: sampler;
@group(0) @binding(5) var<uniform> u_ssgi: SsgiUniforms;

const BLUR_RADIUS: i32 = 2;

fn saturate(v: f32) -> f32 {
    return clamp(v, 0.0, 1.0);
}

fn unpack_view_normal(packed: vec4<f32>) -> vec3<f32> {
    let raw = packed.xyz * 2.0 - 1.0;
    return normalize(select(vec3<f32>(0.0, 0.0, 1.0), raw, dot(raw, raw) > 1e-5));
}

fn linearize_depth(z: f32) -> f32 {
    return 1.0 / max(z, 0.0001);
}

fn resolve_full_uv(half_pixel: vec2<u32>) -> vec2<f32> {
    if (u_ssgi.frame_params.z == 0u) {
        return (vec2<f32>(half_pixel) + vec2<f32>(0.5, 0.5)) * u_ssgi.half_resolution.zw;
    }

    let phase = (half_pixel.x + half_pixel.y + u_ssgi.frame_params.x) & 1u;
    let base = vec2<f32>(half_pixel * 2u);
    let offset = select(vec2<f32>(0.5, 0.5), vec2<f32>(1.5, 1.5), phase == 1u);
    return (base + offset) * u_ssgi.full_resolution.zw;
}

fn half_uv_to_pixel(uv: vec2<f32>) -> vec2<u32> {
    let coord = clamp(
        floor(uv * u_ssgi.half_resolution.xy),
        vec2<f32>(0.0),
        u_ssgi.half_resolution.xy - vec2<f32>(1.0)
    );
    return vec2<u32>(coord);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let center = textureSampleLevel(t_indirect, s_linear, in.uv, 0.0);
    if (center.a <= 0.0) {
        return vec4<f32>(0.0);
    }

    let center_pixel = vec2<u32>(in.position.xy);
    let center_uv = resolve_full_uv(center_pixel);
    let center_depth = textureSampleLevel(t_depth, s_point, center_uv, 0u);
    let center_normal_packed = textureSampleLevel(t_normal, s_point, center_uv, 0.0);
    if (center_depth <= 0.0 || center_normal_packed.a < 0.5) {
        return center;
    }

    let center_linear = linearize_depth(center_depth);
    let center_normal = unpack_view_normal(center_normal_packed);
    let texel_size = u_ssgi.half_resolution.zw;

    var color_sum = center.rgb;
    var weight_sum = 1.0;

    for (var y = -BLUR_RADIUS; y <= BLUR_RADIUS; y++) {
        for (var x = -BLUR_RADIUS; x <= BLUR_RADIUS; x++) {
            if (x == 0 && y == 0) {
                continue;
            }

            let sample_uv = in.uv + vec2<f32>(f32(x), f32(y)) * texel_size;
            if (sample_uv.x < 0.0 || sample_uv.x > 1.0 || sample_uv.y < 0.0 || sample_uv.y > 1.0) {
                continue;
            }

            let sample_indirect = textureSampleLevel(t_indirect, s_linear, sample_uv, 0.0);
            if (sample_indirect.a <= 0.0) {
                continue;
            }

            let sample_pixel = half_uv_to_pixel(sample_uv);
            let sample_full_uv = resolve_full_uv(sample_pixel);
            let sample_depth = textureSampleLevel(t_depth, s_point, sample_full_uv, 0u);
            let sample_normal_packed = textureSampleLevel(t_normal, s_point, sample_full_uv, 0.0);
            if (sample_depth <= 0.0 || sample_normal_packed.a < 0.5) {
                continue;
            }

            let sample_linear = linearize_depth(sample_depth);
            let sample_normal = unpack_view_normal(sample_normal_packed);

            let depth_sigma = max(u_ssgi.reprojection_params.w, 1e-3);
            let depth_delta = center_linear - sample_linear;
            let depth_weight = exp(-(depth_delta * depth_delta) / (2.0 * depth_sigma * depth_sigma));

            let normal_weight = pow(saturate(dot(center_normal, sample_normal)), u_ssgi.lighting_params.z);
            let dist2 = f32(x * x + y * y);
            let spatial_weight = exp(-dist2 / 8.0);

            let weight = depth_weight * normal_weight * spatial_weight;
            color_sum += sample_indirect.rgb * weight;
            weight_sum += weight;
        }
    }

    return vec4<f32>(color_sum / max(weight_sum, 1e-4), center.a);
}