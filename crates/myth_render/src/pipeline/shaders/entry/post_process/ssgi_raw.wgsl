{$ include 'core/full_screen_vertex' $}

{{ struct_definitions }}
{{ binding_code }}
{{ scene_lighting_structs }}

const SSGI_MAX_STEPS: u32 = {{ ssgi_max_steps }}u;

@group(1) @binding(0) var t_depth: texture_depth_2d;
@group(1) @binding(1) var t_normal: texture_2d<f32>;
@group(1) @binding(2) var t_hiz: texture_2d<f32>;
@group(1) @binding(3) var t_source_history: texture_2d<f32>;
@group(1) @binding(4) var t_pmrem: texture_cube<f32>;
@group(1) @binding(5) var s_linear: sampler;
@group(1) @binding(6) var s_point: sampler;
@group(1) @binding(7) var<uniform> u_ssgi: SsgiUniforms;

struct ProjectedSample {
    uv: vec2<f32>,
    depth: f32,
    valid: bool,
};

fn saturate(v: f32) -> f32 {
    return clamp(v, 0.0, 1.0);
}

fn hash12(p: vec2<f32>) -> f32 {
    let h = dot(p, vec2<f32>(127.1, 311.7));
    return fract(sin(h) * 43758.5453123);
}

fn hash22(p: vec2<f32>) -> vec2<f32> {
    return vec2<f32>(
        hash12(p + vec2<f32>(17.0, 59.4)),
        hash12(p + vec2<f32>(91.7, 13.3))
    );
}

fn unpack_view_normal(packed: vec4<f32>) -> vec3<f32> {
    let raw = packed.xyz * 2.0 - 1.0;
    return normalize(select(vec3<f32>(0.0, 0.0, 1.0), raw, dot(raw, raw) > 1e-5));
}

fn depth_to_linear(z: f32) -> f32 {
    return u_render_state.camera_near / max(z, 0.0001);
}

// fn resolve_full_uv(half_pixel: vec2<u32>) -> vec2<f32> {
//     if (u_ssgi.frame_params.z == 0u) {
//         return (vec2<f32>(half_pixel) + vec2<f32>(0.5, 0.5)) * u_ssgi.half_resolution.zw;
//     }

//     let phase = (half_pixel.x + half_pixel.y + u_ssgi.frame_params.x) & 1u;
//     let base = vec2<f32>(half_pixel * 2u);
//     let offset = select(vec2<f32>(0.5, 0.5), vec2<f32>(1.5, 1.5), phase == 1u);
//     return (base + offset) * u_ssgi.full_resolution.zw;
// }

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

fn project_view_position(view_pos: vec3<f32>) -> ProjectedSample {
    let clip = u_render_state.projection_matrix * vec4<f32>(view_pos, 1.0);
    if (clip.w <= 1e-5) {
        return ProjectedSample(vec2<f32>(0.0), 0.0, false);
    }

    let ndc = clip.xyz / clip.w;
    let uv = vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    let in_bounds = uv.x >= 0.0 && uv.x <= 1.0 && uv.y >= 0.0 && uv.y <= 1.0;
    return ProjectedSample(uv, ndc.z, in_bounds);
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

fn sample_hiz_bounds(uv: vec2<f32>, mip: u32) -> vec2<f32> {
    let dims = textureDimensions(t_hiz, i32(mip));
    let coord = clamp(
        vec2<i32>(uv * vec2<f32>(dims)),
        vec2<i32>(0, 0),
        vec2<i32>(dims) - vec2<i32>(1, 1)
    );
    return textureLoad(t_hiz, coord, i32(mip)).xy;
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
    // let frame_jitter = f32(u_ssgi.frame_params.x & 1023u);
    // let random = hash22(vec2<f32>(half_pixel) + vec2<f32>(frame_jitter, 31.0));
    let random_base = hash22(vec2<f32>(half_pixel));
    let frame_index = f32(u_ssgi.frame_params.x % 1024u);
    let golden_offset = vec2<f32>(0.61803398875, 0.75487766624) * frame_index;
    let random = fract(random_base + golden_offset);

    let ray_dir = normalize(make_tangent_basis(view_normal) * cosine_hemisphere(random));

    let max_levels = textureNumLevels(t_hiz);
    let history_available = (u_ssgi.frame_params.w & 2u) != 0u;
    let fallback = sample_environment(ray_dir) * u_ssgi.lighting_params.x;
    let max_distance = u_ssgi.ray_params.y;
    let base_step = max_distance / f32(SSGI_MAX_STEPS);
    let thickness = u_ssgi.ray_params.z;
    let mip_bias = u_ssgi.lighting_params.y;

    var travel = 0.0;

    for (var step: u32 = 0u; step < SSGI_MAX_STEPS; step++) {
        let step_scale = 1.0 + f32(step) * u_ssgi.ray_params.w;
        travel += base_step * step_scale;
        if (travel > max_distance) {
            break;
        }

        let sample_pos = view_pos + ray_dir * travel;
        let projected = project_view_position(sample_pos);
        if (!projected.valid) {
            break;
        }

        let screen_delta = abs((projected.uv - full_uv) * u_ssgi.full_resolution.xy);
        let footprint = max(screen_delta.x, screen_delta.y);
        let mip = u32(clamp(
            floor(log2(max(footprint, 1.0)) + mip_bias),
            0.0,
            f32(max_levels - 1u)
        ));
        let bounds = sample_hiz_bounds(projected.uv, mip);
        if (projected.depth > bounds.y + 1e-4) {
            continue;
        }

        let hit_depth = textureSampleLevel(t_depth, s_point, projected.uv, 0u);
        let hit_normal_packed = textureSampleLevel(t_normal, s_point, projected.uv, 0.0);
        if (hit_depth <= 0.0 || hit_normal_packed.a < 0.5) {
            continue;
        }

        let hit_linear = depth_to_linear(hit_depth);
        let sample_linear = depth_to_linear(projected.depth);
        if (abs(sample_linear - hit_linear) > thickness * max(hit_linear, 1.0)) {
            continue;
        }

        let hit_normal = unpack_view_normal(hit_normal_packed);
        let bounce_visibility = saturate(dot(view_normal, ray_dir)) * saturate(dot(hit_normal, -ray_dir));
        if (bounce_visibility <= 1e-4) {
            continue;
        }

        let source_color = select(
            fallback,
            textureSampleLevel(t_source_history, s_linear, projected.uv, 0.0).rgb,
            history_available
        );
        let attenuation = 1.0 / (1.0 + travel * travel * 0.25);
        return vec4<f32>(source_color * bounce_visibility * attenuation, 1.0);
    }

    return vec4<f32>(fallback, 1.0);
}