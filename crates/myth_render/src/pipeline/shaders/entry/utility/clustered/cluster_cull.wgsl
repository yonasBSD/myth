// Assigns visible punctual lights to each cluster using a fixed-capacity
// light list per cluster to avoid global atomic contention.

{{ binding_code }}
{{ clustered_lighting_structs }}

@group(1) @binding(0) var<uniform> u_clustered_lighting: ClusteredLightingParams;
@group(1) @binding(1) var<storage, read> st_cluster_aabbs: array<ClusterAabb>;
@group(1) @binding(2) var<storage, read_write> st_cluster_records: array<ClusterRecord>;
@group(1) @binding(3) var<storage, read_write> st_cluster_light_indices: array<u32>;

fn sphere_intersects_aabb(
    center: vec3<f32>,
    radius: f32,
    aabb_min: vec3<f32>,
    aabb_max: vec3<f32>,
) -> bool {
    let closest = clamp(center, aabb_min, aabb_max);
    let delta = closest - center;
    return dot(delta, delta) <= radius * radius;
}

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let cluster_index = global_id.x;
    let total_clusters = u_clustered_lighting.grid_dimensions.y;
    if (cluster_index >= total_clusters) {
        return;
    }

    let aabb = st_cluster_aabbs[cluster_index];
    let aabb_min = aabb.min_point.xyz;
    let aabb_max = aabb.max_point.xyz;

    let max_lights_per_cluster = max(u_clustered_lighting.budget.x, 1u);
    let base_offset = cluster_index * max_lights_per_cluster;

    var count = 0u;

    for (var i = 0u; i < u_environment.num_lights; i += 1u) {
        let light = st_lights[i];
        var intersects = false;

        if (light.light_type == 0u || light.range <= 0.0) {
            intersects = true;
        } else {
            let view_pos = (u_render_state.view_matrix * vec4<f32>(light.position, 1.0)).xyz;
            intersects = sphere_intersects_aabb(view_pos, light.range, aabb_min, aabb_max);
        }

        if (intersects) {
            if (count >= max_lights_per_cluster) {
                break;
            }

            st_cluster_light_indices[base_offset + count] = i;
            count += 1u;
        }
    }

    st_cluster_records[cluster_index] = ClusterRecord(base_offset, count, 0u, 0u);
}