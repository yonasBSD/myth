{$ include 'core/full_screen_vertex' $}
{$ include 'modules/raymarch/hiz_traversal' $}

{{ struct_definitions }}
{{ binding_code }}
{{ scene_lighting_structs }}

const SSR_MAX_STEPS: u32 = {{ ssr_max_steps }}u;
const PI: f32 = 3.14159265359;

@group(1) @binding(0) var t_depth: texture_depth_2d;
@group(1) @binding(1) var t_normal: texture_2d<f32>;
@group(1) @binding(2) var t_scene_color: texture_2d<f32>;
@group(1) @binding(3) var t_hiz: texture_2d<f32>;
@group(1) @binding(4) var t_material_data: texture_2d<f32>;
@group(1) @binding(5) var t_specular_data: texture_2d<f32>;
@group(1) @binding(6) var s_linear: sampler;
@group(1) @binding(7) var s_point: sampler;
@group(1) @binding(8) var<uniform> u_ssr: SsrUniforms;
$$ if HIGH_END_NOISE is defined
@group(1) @binding(9) var t_blue_noise: texture_2d_array<f32>;
$$ else
@group(1) @binding(9) var t_blue_noise: texture_2d<f32>;
$$ endif
@group(1) @binding(10) var s_blue_noise: sampler;

{$ include 'entry/utility/blue_noise' $}

struct ProjectedSample {
    unjittered_uv: vec2<f32>,
    jittered_uv: vec2<f32>,
    valid: bool,
};

fn saturate(v: f32) -> f32 {
    return clamp(v, 0.0, 1.0);
}

fn luminance(color: vec3<f32>) -> f32 {
    return dot(max(color, vec3<f32>(0.0)), vec3<f32>(0.2126, 0.7152, 0.0722));
}

fn unpack_view_normal(packed: vec4<f32>) -> vec3<f32> {
    let raw = packed.xyz * 2.0 - 1.0;
    return normalize(select(vec3<f32>(0.0, 0.0, 1.0), raw, dot(raw, raw) > 1e-5));
}

fn depth_to_linear(z: f32) -> f32 {
    return u_ssr.temporal_params.z / max(z, 0.0001);
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

fn importance_sample_ggx(xi: vec2<f32>, normal: vec3<f32>, roughness: f32) -> vec3<f32> {
    let a = roughness * roughness;
    let phi = 2.0 * PI * xi.x;
    let cos_theta = sqrt((1.0 - xi.y) / (1.0 + (a * a - 1.0) * xi.y));
    let sin_theta = sqrt(max(1.0 - cos_theta * cos_theta, 0.0));

    let half_vector = vec3<f32>(
        cos(phi) * sin_theta,
        sin(phi) * sin_theta,
        cos_theta
    );

    let up = select(vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(0.0, 0.0, 1.0), abs(normal.z) < 0.999);
    let tangent = normalize(cross(up, normal));
    let bitangent = cross(normal, tangent);
    return normalize(tangent * half_vector.x + bitangent * half_vector.y + normal * half_vector.z);
}

fn edge_vignette(uv: vec2<f32>) -> f32 {
    let edge_dist = abs(uv - vec2<f32>(0.5)) * 2.0;
    return 1.0 - smoothstep(
        u_ssr.fade_params.x,
        u_ssr.fade_params.y,
        max(edge_dist.x, edge_dist.y)
    );
}

fn backface_fade(ray_dir: vec3<f32>) -> f32 {
    return 1.0 - smoothstep(u_ssr.fade_params.z, u_ssr.fade_params.w, ray_dir.z);
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let pixel = vec2<u32>(in.position.xy);
    let depth = textureSampleLevel(t_depth, s_point, in.uv, 0u);
    let normal_packed = textureSampleLevel(t_normal, s_point, in.uv, 0.0);
    if (depth <= 0.0 || normal_packed.a < 0.5) {
        return vec4<f32>(0.0);
    }

    let material_data = textureSampleLevel(t_material_data, s_point, in.uv, 0.0);
    let specular_data = textureSampleLevel(t_specular_data, s_point, in.uv, 0.0);
    let roughness = material_data.a;
    if (roughness > u_ssr.shading_params.x || luminance(specular_data.rgb) <= 1e-4) {
        return vec4<f32>(0.0);
    }

    let view_pos = reconstruct_view_position(in.uv, depth);
    let view_normal = unpack_view_normal(normal_packed);
    let view_dir = normalize(-view_pos);
    let noise = get_blue_noise(pixel, u_ssr.frame_params.x).rg;
    let half_vector = importance_sample_ggx(noise, view_normal, max(roughness, 0.02));
    let ray_dir = normalize(reflect(-view_dir, half_vector));

    let ndotr = dot(view_normal, ray_dir);
    if (ndotr <= 1e-4) {
        return vec4<f32>(0.0);
    }

    let roughness_fade = 1.0 - smoothstep(
        u_ssr.shading_params.x * 0.35,
        u_ssr.shading_params.x,
        roughness
    );
    let direction_fade = backface_fade(ray_dir);
    let base_confidence = roughness_fade * direction_fade * saturate(ndotr);
    if (base_confidence <= 1e-4) {
        return vec4<f32>(0.0);
    }

    let trace_start_distance = max(u_ssr.ray_params.w, 0.01);
    let trace_start = view_pos + view_normal * trace_start_distance + ray_dir * trace_start_distance;
    let trace_start_projected = project_view_position(trace_start);
    if (!trace_start_projected.valid) {
        return vec4<f32>(0.0);
    }

    var trace_distance = u_ssr.ray_params.y;
    var ray_end = view_pos + ray_dir * trace_distance;
    var ray_end_projected = project_view_position(ray_end);
    for (var retry: u32 = 0u; retry < 4u && !ray_end_projected.valid; retry++) {
        trace_distance *= 0.5;
        ray_end = view_pos + ray_dir * trace_distance;
        ray_end_projected = project_view_position(ray_end);
    }

    if (!ray_end_projected.valid) {
        return vec4<f32>(0.0);
    }

    let clip_start = project_unjittered_clip(trace_start);
    let clip_end = project_unjittered_clip(ray_end);
    let k0 = 1.0 / max(clip_start.w, 1e-5);
    let k1 = 1.0 / max(clip_end.w, 1e-5);
    let q0 = trace_start * k0;
    let q1 = ray_end * k1;

    let trace = trace_screen_space_ray_hiz(
        HiZTraceSegment(
            trace_start_projected.jittered_uv * u_ssr.full_resolution.xy,
            ray_end_projected.jittered_uv * u_ssr.full_resolution.xy,
            q0,
            q1,
            k0,
            k1,
        ),
        HiZTraceConfig(
            u_ssr.full_resolution.xy,
            u_ssr.temporal_params.z,
            u_ssr.ray_params.z,
            u_ssr.shading_params.y,
            textureNumLevels(t_hiz) - 1u,
            max(SSR_MAX_STEPS * 4u, 64u),
        ),
        t_hiz,
        t_depth,
    );

    if (!trace.hit) {
        return vec4<f32>(0.0);
    }

    let hit_depth = textureSampleLevel(t_depth, s_point, trace.uv, 0u);
    if (hit_depth <= 0.0) {
        return vec4<f32>(0.0);
    }

    let hit_linear = depth_to_linear(hit_depth);
    let depth_diff = trace.depth - hit_linear;
    let thickness_limit = u_ssr.ray_params.z * max(hit_linear, 1.0);
    if (depth_diff < 0.0 || depth_diff > thickness_limit) {
        return vec4<f32>(0.0);
    }

    let hit_view_pos = reconstruct_view_position(trace.uv, hit_depth);
    let travel = length(hit_view_pos - view_pos);
    let distance_fade = 1.0 - smoothstep(u_ssr.ray_params.y * 0.6, u_ssr.ray_params.y, travel);
    let hit_uv = jittered_to_unjittered_uv(trace.uv);
    let confidence = base_confidence * edge_vignette(hit_uv) * distance_fade;
    if (confidence <= 1e-4) {
        return vec4<f32>(0.0);
    }

    let hit_color = textureSampleLevel(t_scene_color, s_linear, trace.uv, 0.0).rgb;
    return vec4<f32>(hit_color, confidence);
}