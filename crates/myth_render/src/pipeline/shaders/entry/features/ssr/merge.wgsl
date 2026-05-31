{$ include 'core/full_screen_vertex' $}

{{ struct_definitions }}
{{ binding_code }}
{{ scene_lighting_structs }}

@group(1) @binding(0) var t_scene_color: texture_2d<f32>;
@group(1) @binding(1) var t_clean_reflection: texture_2d<f32>;
@group(1) @binding(2) var t_material_data: texture_2d<f32>;
@group(1) @binding(3) var t_specular_data: texture_2d<f32>;
@group(1) @binding(4) var t_depth: texture_depth_2d;
@group(1) @binding(5) var t_normal: texture_2d<f32>;
@group(1) @binding(6) var s_linear: sampler;
@group(1) @binding(7) var s_point: sampler;
@group(1) @binding(8) var<uniform> u_ssr: SsrUniforms;

fn saturate(v: f32) -> f32 {
    return clamp(v, 0.0, 1.0);
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
    let reflection_extent = vec2<i32>(textureDimensions(t_clean_reflection));
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

fn reconstruct_view_position(uv: vec2<f32>, depth: f32) -> vec3<f32> {
    let ndc = vec4<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    let view_pos = u_render_state.projection_inverse * ndc;
    let safe_w = max(abs(view_pos.w), 1e-6) * sign(view_pos.w + 1e-6);
    return view_pos.xyz / safe_w;
}

fn sample_reflection(full_uv: vec2<f32>, full_linear: f32, full_normal: vec3<f32>) -> vec4<f32> {
    let reflection_extent = vec2<i32>(textureDimensions(t_clean_reflection));
    let full_extent = vec2<i32>(i32(u_ssr.full_resolution.x), i32(u_ssr.full_resolution.y));
    if (all(reflection_extent == full_extent)) {
        return textureSampleLevel(t_clean_reflection, s_linear, full_uv, 0.0);
    }

    let max_coord = reflection_extent - vec2<i32>(1, 1);
    let reflection_pos = full_uv * vec2<f32>(reflection_extent) - vec2<f32>(0.5, 0.5);
    let base_coord = vec2<i32>(floor(reflection_pos));
    let frac = fract(reflection_pos);
    let depth_sigma = max(u_ssr.reprojection_params.z * max(full_linear, 1.0), 1e-3);

    var color_sum = vec3<f32>(0.0);
    var confidence_sum = 0.0;
    var weight_sum = 0.0;

    for (var y: i32 = 0; y <= 1; y++) {
        for (var x: i32 = 0; x <= 1; x++) {
            let sample_coord = clamp(base_coord + vec2<i32>(x, y), vec2<i32>(0, 0), max_coord);
            let sample_reflection = textureLoad(t_clean_reflection, sample_coord, 0);
            if (sample_reflection.a <= 1e-4) {
                continue;
            }

            let sample_uv = (vec2<f32>(sample_coord) + vec2<f32>(0.5, 0.5))
                / vec2<f32>(reflection_extent);
            let sample_surface = sample_surface_conservative(sample_uv);
            let sample_depth = sample_surface.depth;
            let sample_normal_packed = sample_surface.normal_packed;
            if (sample_depth <= 0.0 || sample_normal_packed.a < 0.5) {
                continue;
            }

            let sample_linear = linearize_depth(sample_depth);
            let sample_normal = unpack_view_normal(sample_normal_packed);
            let bilinear_weight_x = select(1.0 - frac.x, frac.x, x == 1);
            let bilinear_weight_y = select(1.0 - frac.y, frac.y, y == 1);
            let spatial_weight = bilinear_weight_x * bilinear_weight_y;
            let depth_delta = full_linear - sample_linear;
            let depth_weight = exp(
                -(depth_delta * depth_delta) / (2.0 * depth_sigma * depth_sigma)
            );
            let normal_weight = pow(
                saturate(dot(full_normal, sample_normal)),
                u_ssr.shading_params.z
            );
            let weight = spatial_weight * depth_weight * normal_weight;

            color_sum += sample_reflection.rgb * weight;
            confidence_sum += sample_reflection.a * weight;
            weight_sum += weight;
        }
    }

    if (weight_sum <= 1e-4) {
        return textureSampleLevel(t_clean_reflection, s_linear, full_uv, 0.0);
    }

    return vec4<f32>(
        color_sum / max(weight_sum, 1e-4),
        confidence_sum / max(weight_sum, 1e-4)
    );
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let scene_color = textureSampleLevel(t_scene_color, s_point, in.uv, 0.0);
    let surface = sample_surface_conservative(in.uv);
    let depth = surface.depth;
    let normal_packed = surface.normal_packed;
    if (depth <= 0.0 || normal_packed.a < 0.5) {
        return scene_color;
    }

    let view_normal = unpack_view_normal(normal_packed);
    let reflection = sample_reflection(in.uv, linearize_depth(depth), view_normal);
    if (reflection.a <= 1e-4) {
        return scene_color;
    }

    let material_data = textureSampleLevel(t_material_data, s_point, in.uv, 0.0);
    let specular_data = textureSampleLevel(t_specular_data, s_point, in.uv, 0.0);
    let roughness = material_data.a;
    if (roughness > u_ssr.shading_params.x) {
        return scene_color;
    }
    let roughness_weight = 1.0 - smoothstep(
        u_ssr.shading_params.x * 0.5,
        u_ssr.shading_params.x,
        roughness
    );
    let blend = reflection.a * roughness_weight;
    let base_specular = specular_data.rgb;
    let ssr_specular = reflection.rgb;
    let base_color = max(scene_color.rgb - base_specular, vec3<f32>(0.0));
    let merged_specular = mix(base_specular, ssr_specular, vec3<f32>(blend));
    return vec4<f32>(base_color + merged_specular, scene_color.a);
}