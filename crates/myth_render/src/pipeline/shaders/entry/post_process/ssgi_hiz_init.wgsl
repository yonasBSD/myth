@group(0) @binding(0) var t_depth: texture_depth_2d;
@group(0) @binding(1) var t_hiz_out: texture_storage_2d<rgba16float, write>;

@compute @workgroup_size(8, 8, 1)
fn main(@builtin(global_invocation_id) gid: vec3<u32>) {
    let dims = textureDimensions(t_hiz_out);
    if (gid.x >= dims.x || gid.y >= dims.y) {
        return;
    }

    let coord = vec2<i32>(gid.xy);
    let depth = textureLoad(t_depth, coord, 0);
    textureStore(t_hiz_out, coord, vec4<f32>(depth, depth, 0.0, 0.0));
}