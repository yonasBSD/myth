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

fn reconstruct_view_position(uv: vec2<f32>, depth: f32) -> vec3<f32> {
    let ndc = vec4<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0, depth, 1.0);
    let view_pos = u_render_state.projection_inverse * ndc;
    let safe_w = max(abs(view_pos.w), 1e-6) * sign(view_pos.w + 1e-6);
    return view_pos.xyz / safe_w;
}

fn fresnel_schlick(f0: vec3<f32>, dot_nv: f32) -> vec3<f32> {
    let x = pow(1.0 - saturate(dot_nv), 5.0);
    return f0 + (vec3<f32>(1.0) - f0) * x;
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let scene_color = textureSampleLevel(t_scene_color, s_point, in.uv, 0.0);
    let reflection = textureSampleLevel(t_clean_reflection, s_linear, in.uv, 0.0);
    if (reflection.a <= 1e-4) {
        return scene_color;
    }

    let depth = textureSampleLevel(t_depth, s_point, in.uv, 0u);
    let normal_packed = textureSampleLevel(t_normal, s_point, in.uv, 0.0);
    if (depth <= 0.0 || normal_packed.a < 0.5) {
        return scene_color;
    }

    let material_data = textureSampleLevel(t_material_data, s_point, in.uv, 0.0);
    let specular_data = textureSampleLevel(t_specular_data, s_point, in.uv, 0.0);
    let roughness = material_data.a;
    if (roughness > u_ssr.shading_params.x) {
        return scene_color;
    }

    let view_pos = reconstruct_view_position(in.uv, depth);
    let view_dir = normalize(-view_pos);
    let view_normal = unpack_view_normal(normal_packed);
    let dot_nv = saturate(dot(view_normal, view_dir));
    let metalness = specular_data.a;
    let f0 = mix(vec3<f32>(0.04), material_data.rgb, metalness);
    let fresnel = fresnel_schlick(f0, dot_nv);
    let roughness_weight = 1.0 - smoothstep(
        u_ssr.shading_params.x * 0.5,
        u_ssr.shading_params.x,
        roughness
    );
    let blend = reflection.a * roughness_weight;
    let base_specular = specular_data.rgb;
    let ssr_specular = reflection.rgb * fresnel;
    let base_color = max(scene_color.rgb - base_specular, vec3<f32>(0.0));
    let merged_specular = mix(base_specular, ssr_specular, vec3<f32>(blend));
    return vec4<f32>(base_color + merged_specular, scene_color.a);
}