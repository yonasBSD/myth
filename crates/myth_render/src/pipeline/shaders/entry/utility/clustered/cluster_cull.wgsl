// Assigns visible local lights to each cluster using only precomputed
// view-space bounding spheres and a compact global light-index allocator.

{{ binding_code }}
{{ scene_lighting_structs }}
{{ clustered_lighting_structs }}

@group(1) @binding(0) var<uniform> u_clustered_lighting: ClusteredLightingParams;
@group(1) @binding(1) var<storage, read_write> st_cluster_records: array<ClusterRecord>;
@group(1) @binding(2) var<storage, read_write> st_cluster_light_indices: array<u32>;
@group(1) @binding(3) var<storage, read_write> st_light_index_allocator: array<atomic<u32>, 1>;
@group(1) @binding(4) var<uniform> u_local_light_buffer_metadata: LightBufferMetadata;
@group(1) @binding(5) var<storage, read> st_light_view_positions: array<vec4<f32>>;

const CLUSTER_CULL_WG_SIZE: u32 = 64u;
const MAX_LOCAL_LIGHTS: u32 = {{ clustered_max_local_lights }};
const ALLOCATOR_OFFSET_SLOT: u32 = 0u;

var<workgroup> wg_plane_normals: array<vec4<f32>, 4>;
var<workgroup> wg_slice_near: f32;
var<workgroup> wg_slice_far: f32;
var<workgroup> wg_cluster_index: u32;
var<workgroup> wg_reserved_offset: u32;
var<workgroup> wg_reserved_count: u32;
var<workgroup> wg_local_match_count: atomic<u32>;
var<workgroup> wg_local_light_indices: array<u32, MAX_LOCAL_LIGHTS>;

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

fn view_ray(pixel: vec2<f32>) -> vec3<f32> {
    let ndc_xy = screen_to_ndc(pixel);
    let view = u_render_state.projection_inverse * vec4<f32>(ndc_xy, 1.0, 1.0);
    return normalize(view.xyz / view.w);
}

fn oriented_plane_normal(edge_a: vec3<f32>, edge_b: vec3<f32>, inside_dir: vec3<f32>) -> vec3<f32> {
    var normal = normalize(cross(edge_a, edge_b));
    if dot(normal, inside_dir) < 0.0 {
        normal = -normal;
    }
    return normal;
}

fn sphere_intersects_cluster_cached(
    center: vec3<f32>,
    radius: f32,
    slice_near: f32,
    slice_far: f32,
    plane_0: vec3<f32>,
    plane_1: vec3<f32>,
    plane_2: vec3<f32>,
    plane_3: vec3<f32>,
) -> bool {
    let light_depth = -center.z;
    if light_depth + radius < slice_near || light_depth - radius > slice_far {
        return false;
    }

    if dot(plane_0, center) < -radius {
        return false;
    }
    if dot(plane_1, center) < -radius {
        return false;
    }
    if dot(plane_2, center) < -radius {
        return false;
    }
    if dot(plane_3, center) < -radius {
        return false;
    }

    return true;
}

@compute @workgroup_size(CLUSTER_CULL_WG_SIZE)
fn main(
    @builtin(workgroup_id) workgroup_id: vec3<u32>,
    @builtin(local_invocation_id) local_id: vec3<u32>,
) {
    let grid_x = max(u_clustered_lighting.screen_dimensions.z, 1u);
    let grid_y = max(u_clustered_lighting.screen_dimensions.w, 1u);
    let grid_z = max(u_clustered_lighting.grid_dimensions.x, 1u);

    if workgroup_id.x >= grid_x || workgroup_id.y >= grid_y || workgroup_id.z >= grid_z {
        return;
    }

    if local_id.x == 0u {
        let cluster_xy = grid_x * grid_y;
        let cluster_index = workgroup_id.z * cluster_xy + workgroup_id.y * grid_x + workgroup_id.x;
        let tile_size = vec2<f32>(
            max(f32(u_clustered_lighting.grid_dimensions.z), 1.0),
            max(f32(u_clustered_lighting.grid_dimensions.w), 1.0),
        );
        let min_pixel = vec2<f32>(f32(workgroup_id.x) * tile_size.x, f32(workgroup_id.y) * tile_size.y);
        let max_pixel = vec2<f32>(
            min(f32(u_clustered_lighting.screen_dimensions.x), f32(workgroup_id.x + 1u) * tile_size.x),
            min(f32(u_clustered_lighting.screen_dimensions.y), f32(workgroup_id.y + 1u) * tile_size.y),
        );
        let top_left = view_ray(min_pixel);
        let top_right = view_ray(vec2<f32>(max_pixel.x, min_pixel.y));
        let bottom_left = view_ray(vec2<f32>(min_pixel.x, max_pixel.y));
        let bottom_right = view_ray(max_pixel);
        let center_dir = normalize(top_left + top_right + bottom_left + bottom_right);

        wg_slice_near = slice_depth(workgroup_id.z);
        wg_slice_far = slice_depth(workgroup_id.z + 1u);
        wg_plane_normals[0] = vec4<f32>(
            oriented_plane_normal(bottom_left, top_left, center_dir),
            0.0,
        );
        wg_plane_normals[1] = vec4<f32>(
            oriented_plane_normal(top_right, bottom_right, center_dir),
            0.0,
        );
        wg_plane_normals[2] = vec4<f32>(
            oriented_plane_normal(top_left, top_right, center_dir),
            0.0,
        );
        wg_plane_normals[3] = vec4<f32>(
            oriented_plane_normal(bottom_right, bottom_left, center_dir),
            0.0,
        );
        wg_cluster_index = cluster_index;
        wg_reserved_offset = 0u;
        wg_reserved_count = 0u;
        atomicStore(&wg_local_match_count, 0u);
    }

    workgroupBarrier();

    // Cache shared cluster bounds into thread-local registers before the hot loops.
    let local_slice_near = wg_slice_near;
    let local_slice_far = wg_slice_far;
    let local_plane_0 = wg_plane_normals[0].xyz;
    let local_plane_1 = wg_plane_normals[1].xyz;
    let local_plane_2 = wg_plane_normals[2].xyz;
    let local_plane_3 = wg_plane_normals[3].xyz;
    let local_light_count = min(
        u_local_light_buffer_metadata.total_light_count,
        arrayLength(&st_light_view_positions),
    );

    for (var light_index = local_id.x; light_index < local_light_count; light_index += CLUSTER_CULL_WG_SIZE) {
        let light_view = st_light_view_positions[light_index];
        if (light_view.w < 0.0) {
            continue;
        }

        if (!sphere_intersects_cluster_cached(
            light_view.xyz,
            light_view.w,
            local_slice_near,
            local_slice_far,
            local_plane_0,
            local_plane_1,
            local_plane_2,
            local_plane_3,
        )) {
            continue;
        }

        let local_match_index = atomicAdd(&wg_local_match_count, 1u);
        if local_match_index < MAX_LOCAL_LIGHTS {
            wg_local_light_indices[local_match_index] = light_index;
        }
    }

    workgroupBarrier();

    if local_id.x == 0u {
        let matched_count = min(atomicLoad(&wg_local_match_count), MAX_LOCAL_LIGHTS);
        let max_light_indices = max(u_clustered_lighting.budget.y, 1u);
        let requested_offset = atomicAdd(&st_light_index_allocator[ALLOCATOR_OFFSET_SLOT], matched_count);
        let clamped_offset = min(requested_offset, max_light_indices);
        let available = max_light_indices - clamped_offset;
        let reserved_count = min(matched_count, available);

        wg_reserved_offset = clamped_offset;
        wg_reserved_count = reserved_count;
        st_cluster_records[wg_cluster_index] = ClusterRecord(clamped_offset, reserved_count);
    }

    workgroupBarrier();

    if wg_reserved_count == 0u {
        return;
    }

    for (var cached_index = local_id.x; cached_index < wg_reserved_count; cached_index += CLUSTER_CULL_WG_SIZE) {
        st_cluster_light_indices[wg_reserved_offset + cached_index] = wg_local_light_indices[cached_index];
    }
}
