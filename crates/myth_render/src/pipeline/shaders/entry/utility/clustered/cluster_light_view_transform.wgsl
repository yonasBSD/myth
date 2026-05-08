// Pre-transforms light positions into view space once per frame so clustered
// culling does not have to repeat the same matrix multiply for every cluster.

{{ binding_code }}

@group(1) @binding(0) var<storage, read_write> st_light_view_positions: array<vec4<f32>>;

const LIGHT_VIEW_TRANSFORM_WG_SIZE: u32 = 64u;
const SPOT_TIGHT_SPHERE_COS_THRESHOLD: f32 = 0.70710678;

fn build_spot_bounding_sphere(light: Struct_lights) -> vec4<f32> {
    if (light.outer_cone_cos < SPOT_TIGHT_SPHERE_COS_THRESHOLD) {
        let view_pos = (u_render_state.view_matrix * vec4<f32>(light.position, 1.0)).xyz;
        return vec4<f32>(view_pos, light.range);
    }

    let cos_sq = max(light.outer_cone_cos * light.outer_cone_cos, 1e-4);
    let radius = 0.5 * light.range / cos_sq;
    let sphere_center = light.position + light.direction * radius;
    let sphere_center_view = (u_render_state.view_matrix * vec4<f32>(sphere_center, 1.0)).xyz;
    return vec4<f32>(sphere_center_view, radius);
}

@compute @workgroup_size(LIGHT_VIEW_TRANSFORM_WG_SIZE)
fn main(@builtin(global_invocation_id) global_id: vec3<u32>) {
    let light_index = global_id.x;
    if light_index >= u_environment.num_lights {
        return;
    }

    let light = st_lights[light_index];
    if (light.light_type == 0u || light.range <= 0.0) {
        st_light_view_positions[light_index] = vec4<f32>(0.0, 0.0, 0.0, -1.0);
        return;
    }

    if (light.light_type == 2u) {
        st_light_view_positions[light_index] = build_spot_bounding_sphere(light);
        return;
    }

    let view_pos = (u_render_state.view_matrix * vec4<f32>(light.position, 1.0)).xyz;
    st_light_view_positions[light_index] = vec4<f32>(view_pos, light.range);
}