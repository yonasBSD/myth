@group(0) @binding(0) var t_prev_hiz: texture_2d<f32>;
@group(0) @binding(1) var t_hiz_out: texture_storage_2d<r32float, write>;

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let out_dims = textureDimensions(t_hiz_out);
    if (gid.x >= out_dims.x || gid.y >= out_dims.y) {
        return;
    }

    let prev_dims = textureDimensions(t_prev_hiz, 0);
    let base = vec2<i32>(gid.xy * 2u);

    let sample_0 = textureLoad(t_prev_hiz, min(base + vec2<i32>(0, 0), vec2<i32>(prev_dims) - vec2<i32>(1)), 0).r;
    let sample_1 = textureLoad(t_prev_hiz, min(base + vec2<i32>(1, 0), vec2<i32>(prev_dims) - vec2<i32>(1)), 0).r;
    let sample_2 = textureLoad(t_prev_hiz, min(base + vec2<i32>(0, 1), vec2<i32>(prev_dims) - vec2<i32>(1)), 0).r;
    let sample_3 = textureLoad(t_prev_hiz, min(base + vec2<i32>(1, 1), vec2<i32>(prev_dims) - vec2<i32>(1)), 0).r;
    let max_depth = max(max(sample_0, sample_1), max(sample_2, sample_3));

    textureStore(t_hiz_out, vec2<i32>(gid.xy), vec4<f32>(max_depth, 0.0, 0.0, 0.0));
}