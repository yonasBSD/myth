@group(0) @binding(0) var t_prev_hiz: texture_2d<f32>;
@group(0) @binding(1) var t_hiz_out: texture_storage_2d<rgba16float, write>;

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let out_dims = textureDimensions(t_hiz_out);
    if (gid.x >= out_dims.x || gid.y >= out_dims.y) {
        return;
    }

    let prev_dims = textureDimensions(t_prev_hiz);
    let base = vec2<i32>(gid.xy * 2u);

    var min_depth = 1.0;
    var max_depth = 0.0;

    for (var y = 0; y < 2; y++) {
        for (var x = 0; x < 2; x++) {
            let sample_coord = min(base + vec2<i32>(x, y), vec2<i32>(prev_dims) - vec2<i32>(1));
            let bounds = textureLoad(t_prev_hiz, sample_coord, 0).xy;
            min_depth = min(min_depth, bounds.x);
            max_depth = max(max_depth, bounds.y);
        }
    }

    textureStore(t_hiz_out, vec2<i32>(gid.xy), vec4<f32>(min_depth, max_depth, 0.0, 0.0));
}