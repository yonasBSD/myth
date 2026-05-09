@group(0) @binding(0) var<storage, read> st_light_count: array<u32>;
@group(0) @binding(1) var<storage, read_write> st_dispatch_args: array<u32>;

const CLUSTER_LIGHT_VIEW_TRANSFORM_WG_SIZE: u32 = 64u;

@compute @workgroup_size(1)
fn main() {
    let light_count = st_light_count[0];
    st_dispatch_args[0] = (light_count + CLUSTER_LIGHT_VIEW_TRANSFORM_WG_SIZE - 1u)
        / CLUSTER_LIGHT_VIEW_TRANSFORM_WG_SIZE;
    st_dispatch_args[1] = 1u;
    st_dispatch_args[2] = 1u;
    st_dispatch_args[3] = 0u;
}