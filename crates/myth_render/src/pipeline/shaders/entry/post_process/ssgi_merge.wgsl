{$ include 'core/full_screen_vertex' $}

{{ struct_definitions }}

@group(0) @binding(0) var t_scene_color: texture_2d<f32>;
@group(0) @binding(1) var t_clean_indirect: texture_2d<f32>;
@group(0) @binding(2) var t_albedo: texture_2d<f32>;
@group(0) @binding(3) var s_linear: sampler;
@group(0) @binding(4) var s_point: sampler;
@group(0) @binding(5) var<uniform> u_ssgi: SsgiUniforms;

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    let scene_color = textureSampleLevel(t_scene_color, s_point, in.uv, 0.0);
    let albedo = textureSampleLevel(t_albedo, s_point, in.uv, 0.0);
    if (albedo.a <= 0.0) {
        return scene_color;
    }

    let indirect = textureSampleLevel(t_clean_indirect, s_linear, in.uv, 0.0);
    if (indirect.a <= 0.0) {
        return scene_color;
    }

    let contribution = indirect.rgb * albedo.rgb * u_ssgi.ray_params.x;
    return vec4<f32>(scene_color.rgb + contribution, scene_color.a);
}