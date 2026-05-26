{$ include 'core/full_screen_vertex' $}
{$ include 'modules/raymarch/hiz_traversal' $}

{{ struct_definitions }}
{{ binding_code }}
{{ scene_lighting_structs }}

const SSGI_MAX_STEPS: u32 = {{ ssgi_max_steps }}u;

@group(1) @binding(0) var t_depth: texture_depth_2d;
@group(1) @binding(1) var t_normal: texture_2d<f32>;
@group(1) @binding(2) var t_source_history: texture_2d<f32>;
@group(1) @binding(3) var t_hiz: texture_2d<f32>;
@group(1) @binding(4) var t_pmrem: texture_cube<f32>;
@group(1) @binding(5) var s_linear: sampler;
@group(1) @binding(6) var s_point: sampler;
@group(1) @binding(7) var<uniform> u_ssgi: SsgiUniforms;
$$ if HIGH_END_NOISE is defined
@group(1) @binding(8) var t_blue_noise: texture_2d_array<f32>;
$$ else
@group(1) @binding(8) var t_blue_noise: texture_2d<f32>;
$$ endif
@group(1) @binding(9) var s_blue_noise: sampler;

{$ include 'entry/utility/blue_noise' $}

struct ProjectedSample {
    unjittered_uv: vec2<f32>,
    jittered_uv: vec2<f32>,
    valid: bool,
};

fn saturate(v: f32) -> f32 {
    return clamp(v, 0.0, 1.0);
}

fn unpack_view_normal(packed: vec4<f32>) -> vec3<f32> {
    let raw = packed.xyz * 2.0 - 1.0;
    return normalize(select(vec3<f32>(0.0, 0.0, 1.0), raw, dot(raw, raw) > 1e-5));
}

fn depth_to_linear(z: f32) -> f32 {
    return u_render_state.camera_near / max(z, 0.0001);
}

fn jitter_uv_offset() -> vec2<f32> {
    return vec2<f32>(-0.5, 0.5) * u_render_state.jitter;
}

fn jittered_to_unjittered_uv(uv: vec2<f32>) -> vec2<f32> {
    return uv - jitter_uv_offset();
}

fn unjittered_to_jittered_uv(uv: vec2<f32>) -> vec2<f32> {
    return uv + jitter_uv_offset();
}

fn resolve_full_uv(half_pixel: vec2<u32>) -> vec2<f32> {
    if (u_ssgi.frame_params.z == 0u) {
        return (vec2<f32>(half_pixel) + vec2<f32>(0.5, 0.5)) * u_ssgi.half_resolution.zw;
    }

    let frame = u_ssgi.frame_params.x;
    let base = vec2<f32>(half_pixel * 2u);

    // generate a 4-frame 2x2 traversal pattern (similar to Quincunx sampling)
    let offset_x = f32((frame & 1u) ^ ((frame & 2u) >> 1u));
    let offset_y = f32((frame & 2u) >> 1u);
    
    let offset = vec2<f32>(offset_x + 0.5, offset_y + 0.5);
    return (base + offset) * u_ssgi.full_resolution.zw;
}

fn reconstruct_view_position(uv: vec2<f32>, depth: f32) -> vec3<f32> {
    let ndc = vec4<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    let view_pos = u_render_state.projection_inverse * ndc;
    let safe_w = max(abs(view_pos.w), 1e-6) * sign(view_pos.w + 1e-6);
    return view_pos.xyz / safe_w;
}

fn project_unjittered_clip(view_pos: vec3<f32>) -> vec4<f32> {
    return u_render_state.unjittered_projection_matrix * vec4<f32>(view_pos, 1.0);
}

fn project_view_position(view_pos: vec3<f32>) -> ProjectedSample {
    let clip = project_unjittered_clip(view_pos);
    if (clip.w <= 1e-5) {
        return ProjectedSample(vec2<f32>(0.0), vec2<f32>(0.0), false);
    }

    let ndc = clip.xyz / clip.w;
    let unjittered_uv = vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    let jittered_uv = unjittered_to_jittered_uv(unjittered_uv);
    let in_bounds = unjittered_uv.x >= 0.0 && unjittered_uv.x <= 1.0
        && unjittered_uv.y >= 0.0 && unjittered_uv.y <= 1.0
        && jittered_uv.x >= 0.0 && jittered_uv.x <= 1.0
        && jittered_uv.y >= 0.0 && jittered_uv.y <= 1.0;
    return ProjectedSample(unjittered_uv, jittered_uv, in_bounds);
}

fn make_tangent_basis(normal: vec3<f32>) -> mat3x3<f32> {
    let up = select(vec3<f32>(0.0, 0.0, 1.0), vec3<f32>(0.0, 1.0, 0.0), abs(normal.z) > 0.999);
    let tangent = normalize(cross(up, normal));
    let bitangent = cross(normal, tangent);
    return mat3x3<f32>(tangent, bitangent, normal);
}

fn cosine_hemisphere(rnd: vec2<f32>) -> vec3<f32> {
    let phi = 6.28318530718 * rnd.x;
    let cos_theta = sqrt(max(1.0 - rnd.y, 0.0));
    let sin_theta = sqrt(max(rnd.y, 0.0));
    return vec3<f32>(cos(phi) * sin_theta, sin(phi) * sin_theta, cos_theta);
}

fn sample_environment(view_dir: vec3<f32>) -> vec3<f32> {
    let view_rot = mat3x3<f32>(
        u_render_state.view_matrix[0].xyz,
        u_render_state.view_matrix[1].xyz,
        u_render_state.view_matrix[2].xyz
    );
    var world_dir = normalize(transpose(view_rot) * view_dir);

    let s = sin(u_environment.env_map_rotation);
    let c = cos(u_environment.env_map_rotation);
    world_dir = vec3<f32>(
        world_dir.x * c - world_dir.z * s,
        world_dir.y,
        world_dir.x * s + world_dir.z * c
    );

    let mip_level = u_environment.env_map_max_mip_level * 0.5;
    let env = textureSampleLevel(t_pmrem, s_linear, world_dir, mip_level).rgb;
    return env * u_environment.env_map_intensity + u_environment.ambient_light;
}

fn edge_vignette(uv: vec2<f32>) -> f32 {
    let fade_start = clamp(u_ssgi.merge_params.z, 0.0, 0.999);
    let fade_end = max(u_ssgi.merge_params.w, fade_start + 1e-3);
    let edge_dist = abs(uv - vec2<f32>(0.5)) * 2.0;
    return 1.0 - smoothstep(fade_start, fade_end, max(edge_dist.x, edge_dist.y));
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let half_pixel = vec2<u32>(in.position.xy);
    let full_uv = resolve_full_uv(half_pixel);
    let depth = textureSampleLevel(t_depth, s_point, full_uv, 0u);
    let normal_packed = textureSampleLevel(t_normal, s_point, full_uv, 0.0);

    if (depth <= 0.0 || normal_packed.a < 0.5) {
        return vec4<f32>(0.0);
    }

    let view_pos = reconstruct_view_position(full_uv, depth);
    let view_normal = unpack_view_normal(normal_packed);
    let noise_vec4 = get_blue_noise(half_pixel, u_ssgi.frame_params.x);
    let random = noise_vec4.rg;

    let ray_dir = normalize(make_tangent_basis(view_normal) * cosine_hemisphere(random));

    let history_available = (u_ssgi.frame_params.w & 2u) != 0u && (u_ssgi.frame_params.w & 4u) == 0u;
    let fallback = sample_environment(ray_dir) * u_ssgi.lighting_params.x;
    let max_distance = u_ssgi.ray_params.y;
    let thickness = u_ssgi.ray_params.z;
    let trace_start_distance = max(u_ssgi.ray_params.w, 0.01);
    let trace_start = view_pos + ray_dir * trace_start_distance;
    let trace_start_projected = project_view_position(trace_start);
    if (!trace_start_projected.valid) {
        return vec4<f32>(fallback, 1.0);
    }

    var trace_distance = max_distance;
    var ray_end = view_pos + ray_dir * trace_distance;
    var ray_end_projected = project_view_position(ray_end);
    for (var retry: u32 = 0u; retry < 4u && !ray_end_projected.valid; retry++) {
        trace_distance *= 0.5;
        ray_end = view_pos + ray_dir * trace_distance;
        ray_end_projected = project_view_position(ray_end);
    }

    if (!ray_end_projected.valid) {
        return vec4<f32>(fallback, 1.0);
    }

    let clip_start = project_unjittered_clip(trace_start);
    let clip_end = project_unjittered_clip(ray_end);
    let k0 = 1.0 / max(clip_start.w, 1e-5);
    let k1 = 1.0 / max(clip_end.w, 1e-5);
    let q0 = trace_start * k0;
    let q1 = ray_end * k1;

    let trace = trace_screen_space_ray_hiz(
        HiZTraceSegment(
            trace_start_projected.jittered_uv * u_ssgi.full_resolution.xy,
            ray_end_projected.jittered_uv * u_ssgi.full_resolution.xy,
            q0,
            q1,
            k0,
            k1,
        ),
        HiZTraceConfig(
            u_ssgi.full_resolution.xy,
            u_render_state.camera_near,
            u_ssgi.ray_params.z,
            u_ssgi.lighting_params.y,
            // textureNumLevels(t_hiz) - 1u,
            min(textureNumLevels(t_hiz) - 1u, 4u),
            max(SSGI_MAX_STEPS * 4u, 48u),
        ),
        t_hiz,
        t_depth,
    );

    if (!trace.hit) {
        return vec4<f32>(fallback, 1.0);
    }

    let hit_depth = textureSampleLevel(t_depth, s_point, trace.uv, 0u);
    if (hit_depth <= 0.0) {
        return vec4<f32>(fallback, 1.0);
    }

    let hit_linear = depth_to_linear(hit_depth);
    let depth_diff = trace.depth - hit_linear;
    let depth_scaled_thickness = thickness * max(hit_linear, 1.0);
    let max_possible_thickness = select(
        depth_scaled_thickness,
        max(depth_scaled_thickness, max(thickness, 0.05) * 10.0),
        u_ssgi.denoise_params.z != 0u
    );
    if (depth_diff < 0.0 || depth_diff > max_possible_thickness) {
        return vec4<f32>(fallback, 1.0);
    }

    let hit_normal_packed = textureSampleLevel(t_normal, s_point, trace.uv, 0.0);
    if (hit_normal_packed.a < 0.5) {
        return vec4<f32>(fallback, 1.0);
    }

    let hit_normal = unpack_view_normal(hit_normal_packed);
    let thickness_limit = select(
        depth_scaled_thickness,
        max(thickness, 0.05) / max(saturate(abs(hit_normal.z)), 0.1),
        u_ssgi.denoise_params.z != 0u
    );
    if (depth_diff > thickness_limit) {
        return vec4<f32>(fallback, 1.0);
    }

    let bounce_visibility = saturate(dot(hit_normal, -ray_dir));
    if (bounce_visibility <= 1e-4) {
        return vec4<f32>(0.0, 0.0, 0.0, 1.0);
    }

    let hit_unjittered_uv = jittered_to_unjittered_uv(trace.uv);
    var source_color = fallback;
    if (history_available) {
        let history_color = textureSampleLevel(t_source_history, s_linear, trace.uv, 0.0).rgb;
        source_color = mix(fallback, history_color, edge_vignette(hit_unjittered_uv));
    }

    let hit_view_pos = reconstruct_view_position(trace.uv, hit_depth);
    let travel = length(hit_view_pos - view_pos);
    let attenuation = 1.0 / (1.0 + travel * travel * 0.25);
    return vec4<f32>(source_color * bounce_visibility * attenuation, 1.0);
}