// Builds view-space cluster AABBs for the current camera frustum.

{{ binding_code }}
{{ clustered_lighting_structs }}

@group(1) @binding(0) var<uniform> u_clustered_lighting: ClusteredLightingParams;
@group(1) @binding(1) var<storage, read_write> st_cluster_aabbs: array<ClusterAabb>;

fn screen_to_ndc(pixel: vec2<f32>) -> vec2<f32> {
    let size = vec2<f32>(
        max(f32(u_clustered_lighting.screen_dimensions.x), 1.0),
        max(f32(u_clustered_lighting.screen_dimensions.y), 1.0),
    );
    let uv = pixel / size;
    return vec2<f32>(uv.x * 2.0 - 1.0, 1.0 - uv.y * 2.0);
}

fn slice_depth(slice: u32) -> f32 {
    let near_plane = u_clustered_lighting.depth_params.x;
    let far_plane = u_clustered_lighting.depth_params.y;
    let slice_count = max(f32(u_clustered_lighting.grid_dimensions.x), 1.0);
    let ratio = max(far_plane / near_plane, 1.0001);
    return near_plane * pow(ratio, f32(slice) / slice_count);
}

fn unproject_view(pixel: vec2<f32>, linear_depth: f32) -> vec3<f32> {
    let ndc_xy = screen_to_ndc(pixel);
    let ndc_z = u_clustered_lighting.depth_params.x / max(linear_depth, 0.0001);
    let view = u_render_state.projection_inverse * vec4<f32>(ndc_xy, ndc_z, 1.0);
    return view.xyz / view.w;
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let cluster_index = global_id.x;
    let total_clusters = u_clustered_lighting.grid_dimensions.y;
    if (cluster_index >= total_clusters) {
        return;
    }

    let grid_x = max(u_clustered_lighting.screen_dimensions.z, 1u);
    let grid_y = max(u_clustered_lighting.screen_dimensions.w, 1u);
    let grid_z = max(u_clustered_lighting.grid_dimensions.x, 1u);
    let cluster_xy = grid_x * grid_y;

    let z = cluster_index / cluster_xy;
    let xy_index = cluster_index - z * cluster_xy;
    let y = xy_index / grid_x;
    let x = xy_index - y * grid_x;

    let tile_size = vec2<f32>(
        max(f32(u_clustered_lighting.grid_dimensions.z), 1.0),
        max(f32(u_clustered_lighting.grid_dimensions.w), 1.0),
    );
    let min_pixel = vec2<f32>(f32(x) * tile_size.x, f32(y) * tile_size.y);
    let max_pixel = vec2<f32>(
        min(f32(u_clustered_lighting.screen_dimensions.x), f32(x + 1u) * tile_size.x),
        min(f32(u_clustered_lighting.screen_dimensions.y), f32(y + 1u) * tile_size.y),
    );

    let near_depth = slice_depth(z);
    let far_depth = slice_depth(min(z + 1u, grid_z));

    let corners = array<vec2<f32>, 4>(
        min_pixel,
        vec2<f32>(max_pixel.x, min_pixel.y),
        vec2<f32>(min_pixel.x, max_pixel.y),
        max_pixel,
    );

    var min_point = vec3<f32>(1e30, 1e30, 1e30);
    var max_point = vec3<f32>(-1e30, -1e30, -1e30);

    for (var i = 0u; i < 4u; i += 1u) {
        let near_corner = unproject_view(corners[i], near_depth);
        let far_corner = unproject_view(corners[i], far_depth);
        min_point = min(min_point, min(near_corner, far_corner));
        max_point = max(max_point, max(near_corner, far_corner));
    }

    st_cluster_aabbs[cluster_index].min_point = vec4<f32>(min_point, 0.0);
    st_cluster_aabbs[cluster_index].max_point = vec4<f32>(max_point, 0.0);
}