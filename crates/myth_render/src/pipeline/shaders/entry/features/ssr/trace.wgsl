{$ include 'core/full_screen_vertex' $}
{$ include 'modules/raymarch/hiz_traversal' $}

{{ struct_definitions }}
{{ binding_code }}
{{ scene_lighting_structs }}

const SSR_MAX_STEPS: u32 = {{ ssr_max_steps }}u;
const PI: f32 = 3.14159265359;
$$ if SSR_TRACE_DIAGNOSTICS is defined
const TRACE_STAGE_SURFACE_INVALID: f32 = 1.0;
const TRACE_STAGE_MATERIAL_REJECT: f32 = 2.0;
const TRACE_STAGE_DIRECTION_REJECT: f32 = 3.0;
const TRACE_STAGE_BASE_CONFIDENCE_REJECT: f32 = 4.0;
const TRACE_STAGE_ENDPOINT_INVALID: f32 = 5.0;
const TRACE_STAGE_HIZ_MISS: f32 = 6.0;
const TRACE_STAGE_THICKNESS_REJECT: f32 = 7.0;
const TRACE_STAGE_THICKNESS_FADE_REJECT: f32 = 8.0;
const TRACE_STAGE_NORMAL_REJECT: f32 = 9.0;
const TRACE_STAGE_CONFIDENCE_REJECT: f32 = 10.0;
const TRACE_STAGE_HIT: f32 = 11.0;
$$ endif

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

struct TraceOutput {
    @location(0) reflection: vec4<f32>,
    $$ if SSR_TRACE_DIAGNOSTICS is defined
    @location(1) debug_data: vec4<f32>,
    $$ endif
};

fn saturate(v: f32) -> f32 {
    return clamp(v, 0.0, 1.0);
}

fn luminance(color: vec3<f32>) -> f32 {
    return dot(max(color, vec3<f32>(0.0)), vec3<f32>(0.2126, 0.7152, 0.0722));
}

fn fresnel_schlick(f0: vec3<f32>, dot_vh: f32) -> vec3<f32> {
    let x = pow(1.0 - saturate(dot_vh), 5.0);
    return f0 + (vec3<f32>(1.0) - f0) * x;
}

fn unpack_view_normal(packed: vec4<f32>) -> vec3<f32> {
    let raw = packed.xyz * 2.0 - 1.0;
    return normalize(select(vec3<f32>(0.0, 0.0, 1.0), raw, dot(raw, raw) > 1e-5));
}

fn depth_to_linear(z: f32) -> f32 {
    return u_ssr.temporal_params.z / max(z, 0.0001);
}

fn jitter_uv_offset() -> vec2<f32> {
    return vec2<f32>(0.5, -0.5) * u_render_state.jitter;
}

fn jittered_to_unjittered_uv(uv: vec2<f32>) -> vec2<f32> {
    return uv - jitter_uv_offset();
}

fn unjittered_to_jittered_uv(uv: vec2<f32>) -> vec2<f32> {
    return uv + jitter_uv_offset();
}

fn resolve_full_res_coord(pixel: vec2<u32>) -> vec2<i32> {
    let full_extent = vec2<i32>(i32(u_ssr.full_resolution.x), i32(u_ssr.full_resolution.y));
    let scale = select(vec2<i32>(1, 1), vec2<i32>(2, 2), u_ssr.denoise_params.y != 0u);
    return clamp(
        vec2<i32>(pixel) * scale,
        vec2<i32>(0, 0),
        full_extent - vec2<i32>(1, 1)
    );
}

fn full_res_coord_to_uv(coord: vec2<i32>) -> vec2<f32> {
    return (vec2<f32>(coord) + vec2<f32>(0.5, 0.5)) / u_ssr.full_resolution.xy;
}

fn reconstruct_view_position(uv: vec2<f32>, depth: f32) -> vec3<f32> {
    let unjittered_uv = jittered_to_unjittered_uv(uv);
    let ndc = vec4<f32>(
        unjittered_uv.x * 2.0 - 1.0,
        1.0 - unjittered_uv.y * 2.0,
        depth,
        1.0,
    );
    let view_pos = u_render_state.unjittered_projection_inverse * ndc;
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
    let up = select(vec3<f32>(1.0, 0.0, 0.0), vec3<f32>(0.0, 0.0, 1.0), abs(normal.z) < 0.999);
    let tangent = normalize(cross(up, normal));
    let bitangent = cross(normal, tangent);
    return mat3x3<f32>(tangent, bitangent, normal);
}

fn sample_visible_ggx_half_vector(
    xi: vec2<f32>,
    normal: vec3<f32>,
    view_dir: vec3<f32>,
    roughness: f32,
) -> vec3<f32> {
    let alpha = max(roughness * roughness, 0.001);
    let basis = make_tangent_basis(normal);
    let view_local_raw = transpose(basis) * view_dir;
    let view_local = normalize(vec3<f32>(view_local_raw.xy, max(view_local_raw.z, 1e-4)));
    let stretched_view = normalize(vec3<f32>(alpha * view_local.x, alpha * view_local.y, view_local.z));
    let lensq = dot(stretched_view.xy, stretched_view.xy);
    let t1 = select(
        vec3<f32>(1.0, 0.0, 0.0),
        normalize(vec3<f32>(-stretched_view.y, stretched_view.x, 0.0)),
        lensq > 1e-6
    );
    let t2 = cross(stretched_view, t1);

    let r = sqrt(xi.x);
    let phi = 2.0 * PI * xi.y;
    let p1 = r * cos(phi);
    var p2 = r * sin(phi);
    let s = 0.5 * (1.0 + stretched_view.z);
    p2 = mix(sqrt(max(1.0 - p1 * p1, 0.0)), p2, s);

    let nh = p1 * t1
        + p2 * t2
        + sqrt(max(1.0 - p1 * p1 - p2 * p2, 0.0)) * stretched_view;
    let half_local = normalize(vec3<f32>(alpha * nh.x, alpha * nh.y, max(nh.z, 0.0)));
    return normalize(basis * half_local);
}

fn smith_ggx_g1(dot_nx: f32, alpha: f32) -> f32 {
    let clamped_dot = saturate(dot_nx);
    let a2 = alpha * alpha;
    let dot2 = clamped_dot * clamped_dot;
    return (2.0 * clamped_dot)
        / max(clamped_dot + sqrt(a2 + (1.0 - a2) * dot2), 1e-4);
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

$$ if SSR_TRACE_DIAGNOSTICS is defined
fn encode_trace_stage(stage: f32, near_clip_active: bool) -> f32 {
    return stage + select(0.0, 0.5, near_clip_active);
}
$$ endif

@fragment
fn fs_main(in: VertexOutput) -> TraceOutput {
    var out: TraceOutput;
    out.reflection = vec4<f32>(0.0);
    $$ if SSR_TRACE_DIAGNOSTICS is defined
    out.debug_data = vec4<f32>(0.0);
    $$ endif

    let pixel = vec2<u32>(in.position.xy);
    let full_res_coord = resolve_full_res_coord(pixel);
    let surface_uv = full_res_coord_to_uv(full_res_coord);
    let depth = textureLoad(t_depth, full_res_coord, 0);
    let normal_packed = textureLoad(t_normal, full_res_coord, 0);
    if (depth <= 0.0 || normal_packed.a < 0.5) {
        $$ if SSR_TRACE_DIAGNOSTICS is defined
        out.debug_data = vec4<f32>(0.0, 0.0, 0.0, TRACE_STAGE_SURFACE_INVALID);
        $$ endif
        return out;
    }

    let material_data = textureLoad(t_material_data, full_res_coord, 0);
    let specular_data = textureLoad(t_specular_data, full_res_coord, 0);
    let roughness = material_data.a;
    if (roughness > u_ssr.shading_params.x || luminance(specular_data.rgb) <= 1e-4) {
        $$ if SSR_TRACE_DIAGNOSTICS is defined
        out.debug_data = vec4<f32>(0.0, 0.0, 0.0, TRACE_STAGE_MATERIAL_REJECT);
        $$ endif
        return out;
    }

    // surface_uv is the unjittered pixel-centre UV; pass the jittered form so the
    // internal jitter-stripping inside reconstruct_view_position cancels cleanly.
    let view_pos = reconstruct_view_position(unjittered_to_jittered_uv(surface_uv), depth);
    let view_normal = unpack_view_normal(normal_packed);
    let view_dir = normalize(-view_pos);
    let noise = get_blue_noise(pixel, u_ssr.frame_params.x).rg;
    let half_vector = sample_visible_ggx_half_vector(
        noise,
        view_normal,
        view_dir,
        max(roughness, 0.02)
    );
    let ray_dir = normalize(reflect(-view_dir, half_vector));

    let ndotr = dot(view_normal, ray_dir);
    if (ndotr <= 1e-4) {
        $$ if SSR_TRACE_DIAGNOSTICS is defined
        out.debug_data = vec4<f32>(0.0, 0.0, 0.0, TRACE_STAGE_DIRECTION_REJECT);
        $$ endif
        return out;
    }

    let roughness_fade = 1.0 - smoothstep(
        u_ssr.shading_params.x * 0.35,
        u_ssr.shading_params.x,
        roughness
    );
    let direction_fade = backface_fade(ray_dir);
    let base_confidence = roughness_fade * direction_fade * saturate(ndotr);
    if (base_confidence <= 1e-4) {
        $$ if SSR_TRACE_DIAGNOSTICS is defined
        out.debug_data = vec4<f32>(0.0, 0.0, 0.0, TRACE_STAGE_BASE_CONFIDENCE_REJECT);
        $$ endif
        return out;
    }

    let trace_start_distance = max(u_ssr.ray_params.w, 0.01);
    let trace_start = view_pos + view_normal * trace_start_distance + ray_dir * trace_start_distance;
    let trace_start_projected = project_view_position(trace_start);
    if (!trace_start_projected.valid) {
        $$ if SSR_TRACE_DIAGNOSTICS is defined
        out.debug_data = vec4<f32>(0.0, 0.0, 0.0, TRACE_STAGE_ENDPOINT_INVALID);
        $$ endif
        return out;
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
        $$ if SSR_TRACE_DIAGNOSTICS is defined
        out.debug_data = vec4<f32>(0.0, 0.0, 0.0, TRACE_STAGE_ENDPOINT_INVALID);
        $$ endif
        return out;
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
        $$ if SSR_TRACE_DIAGNOSTICS is defined
        out.debug_data = vec4<f32>(0.0, 0.0, 0.0, TRACE_STAGE_HIZ_MISS);
        $$ endif
        return out;
    }

    let hit_depth = textureSampleLevel(t_depth, s_point, trace.uv, 0u);
    if (hit_depth <= 0.0) {
        $$ if SSR_TRACE_DIAGNOSTICS is defined
        out.debug_data = vec4<f32>(0.0, 0.0, 0.0, TRACE_STAGE_HIZ_MISS);
        $$ endif
        return out;
    }

    let hit_linear = depth_to_linear(hit_depth);
    let depth_diff = trace.depth - hit_linear;
    let thickness_limit = u_ssr.ray_params.z * max(hit_linear, 1.0);
    if (depth_diff < 0.0 || depth_diff > thickness_limit) {
        $$ if SSR_TRACE_DIAGNOSTICS is defined
        out.debug_data = vec4<f32>(0.0, 0.0, 0.0, TRACE_STAGE_THICKNESS_REJECT);
        $$ endif
        return out;
    }

    let hit_view_pos = reconstruct_view_position(trace.uv, hit_depth);
    let travel = length(hit_view_pos - view_pos);
    let distance_fade = 1.0 - smoothstep(u_ssr.ray_params.y * 0.6, u_ssr.ray_params.y, travel);
    let hit_uv = jittered_to_unjittered_uv(trace.uv);
    let confidence = base_confidence * edge_vignette(hit_uv) * distance_fade;
    if (confidence <= 1e-4) {
        $$ if SSR_TRACE_DIAGNOSTICS is defined
        out.debug_data = vec4<f32>(0.0, 0.0, 0.0, TRACE_STAGE_CONFIDENCE_REJECT);
        $$ endif
        return out;
    }

    $$ if SSR_TRACE_DIAGNOSTICS is defined
    let hit_projected = project_view_position(hit_view_pos);
    let reprojection_delta_pixels = select(
        vec2<f32>(0.0, 0.0),
        (hit_projected.jittered_uv - trace.uv) * u_ssr.full_resolution.xy,
        hit_projected.valid
    );
    let reprojection_error = length(reprojection_delta_pixels);
    $$ endif

    let hit_color = textureSampleLevel(t_scene_color, s_linear, trace.uv, 0.0).rgb;
    let metalness = specular_data.a;
    let f0 = mix(vec3<f32>(0.04), material_data.rgb, metalness);
    let v_dot_h = saturate(dot(view_dir, half_vector));
    let alpha = max(roughness * roughness, 0.001);
    let g1_v = smith_ggx_g1(saturate(dot(view_normal, view_dir)), alpha);
    let g1_l = smith_ggx_g1(saturate(dot(view_normal, ray_dir)), alpha);
    let g2 = g1_v * g1_l;
    let brdf_weight = fresnel_schlick(f0, v_dot_h) * (g2 / max(g1_v, 1e-4));
    let final_radiance = hit_color * brdf_weight;
    out.reflection = vec4<f32>(final_radiance, confidence);
    $$ if SSR_TRACE_DIAGNOSTICS is defined
    out.debug_data = vec4<f32>(
        reprojection_delta_pixels,
        reprojection_error,
        TRACE_STAGE_HIT
    );
    $$ endif
    return out;
}