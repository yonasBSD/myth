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

@fragment
fn fs_main(in: VertexOutput) -> TemporalOutput {
    var out: TemporalOutput;
    out.indirect = vec4<f32>(0.0);
    out.history_meta = vec4<f32>(0.0);

    let half_pixel = vec2<u32>(in.position.xy);
    let full_uv = resolve_full_uv(half_pixel);
    let current_depth = textureSampleLevel(t_depth, s_point, full_uv, 0u);
    let current_normal_packed = textureSampleLevel(t_normal, s_point, full_uv, 0.0);

    if (current_depth <= 0.0 || current_normal_packed.a < 0.5) {
        return out;
    }

    let current_normal = unpack_view_normal(current_normal_packed);
    let current_linear = linearize_depth(current_depth);

    var indirect = textureSampleLevel(t_raw_indirect, s_linear, in.uv, 0.0);
    var accepted_history = false;

    if ((u_ssgi.frame_params.w & 1u) != 0u) {
        let velocity = textureSampleLevel(t_velocity, s_point, full_uv, 0.0).rg;
        let history_uv = in.uv - velocity;

        if (history_uv.x >= 0.0 && history_uv.x <= 1.0 && history_uv.y >= 0.0 && history_uv.y <= 1.0) {
            let hist_meta = textureSampleLevel(t_history_meta, s_linear, history_uv, 0.0);
            let hist_normal = unpack_view_normal(vec4<f32>(hist_meta.rgb, 1.0));
            let hist_linear = hist_meta.a;

            if (dot(current_normal, hist_normal) >= u_ssgi.reprojection_params.y
                && abs(current_linear - hist_linear) <= u_ssgi.reprojection_params.z * max(current_linear, 1.0)) {
                let hist_indirect = textureSampleLevel(t_history_indirect, s_linear, history_uv, 0.0);
                let current_weight = max(u_ssgi.reprojection_params.x, 1.0 / (hist_indirect.a + 1.0));
                indirect = vec4<f32>(
                    mix(hist_indirect.rgb, indirect.rgb, current_weight),
                    min(hist_indirect.a + 1.0, 32.0)
                );
                accepted_history = true;
            }
        }
    }

    if (!accepted_history) {
        indirect.a = max(indirect.a, 1.0);
    }

    out.indirect = indirect;
    out.history_meta = vec4<f32>(current_normal_packed.rgb, current_linear);
    return out;
}