// Pre-transforms light positions into view space once per frame so clustered
// culling does not have to repeat the same matrix multiply for every cluster.

{{ binding_code }}

@group(1) @binding(0) var<storage, read_write> st_light_view_positions: array<vec4<f32>>;

const LIGHT_VIEW_TRANSFORM_WG_SIZE: u32 = 64u;

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

    let view_pos = (u_render_state.view_matrix * vec4<f32>(light.position, 1.0)).xyz;
    st_light_view_positions[light_index] = vec4<f32>(view_pos, light.range);
}