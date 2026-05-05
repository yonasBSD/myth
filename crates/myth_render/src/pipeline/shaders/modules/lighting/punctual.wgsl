// ── Punctual Light Evaluation (Pure Function Module) ─────────────────────
//
// Resolves a light's type (directional / point / spot) and computes
// incident light direction, color, and distance/spot attenuation.
// Dispatches shadow queries to modules/lighting/shadow when enabled.
//
// Depends on:
//   - core/common.wgsl (getDistanceAttenuation, getSpotAttenuation, IncidentLight)
//   - modules/lighting/shadow.wgsl (sample_shadow, sample_point_shadow)

{$ include 'modules/lighting/shadow' $}

fn get_light_info( light: Struct_lights, geometry: GeometricContext ) -> IncidentLight {
    let light_type = light.light_type;
    var light_info: IncidentLight;

    light_info.visible = true;
    light_info.color = light.color.rgb * light.intensity;

    if ( light_type == 0u ) {
        light_info.direction = -light.direction.xyz;
    } else if ( light_type == 1u ) {
        let i_vector = light.position - geometry.position;
        light_info.direction = normalize(i_vector);
        let light_distance = length(i_vector);
        light_info.color *= getDistanceAttenuation( light_distance, light.range, light.decay );
        light_info.visible = any(light_info.color != vec3<f32>(0.0));
    } else if ( light_type == 2u ) {
        let i_vector = light.position - geometry.position;
        light_info.direction = normalize(i_vector);
        let angle_cos = dot(light_info.direction, -light.direction.xyz);
        let spot_attenuation = getSpotAttenuation(light.outer_cone_cos, light.inner_cone_cos, angle_cos);
        if ( spot_attenuation > 0.0 ) {
            let light_distance = length( i_vector );
            light_info.color = light.color.rgb * light.intensity;
            light_info.color *= spot_attenuation;
            light_info.color *= getDistanceAttenuation( light_distance, light.range, light.decay );
            light_info.visible = any(light_info.color != vec3<f32>(0.0));
        } else {
            light_info.color = vec3<f32>( 0.0 );
            light_info.visible = false;
        }

    }
    return light_info;
}

fn evaluate_light_visibility(
    light_idx: u32, 
    geometry: GeometricContext
) -> IncidentLight {
    let light = st_lights[light_idx];
    var punctual_light = get_light_info(light, geometry);

    $$ if HAS_SHADOWS and RECEIVE_SHADOWS
    if (punctual_light.visible) {
        let shadow_pos = geometry.position + geometry.normal * light.shadow_normal_bias;
        var shadow = 1.0;

        if (light.light_type == 1u && light.point_shadow_index >= 0) {
            shadow = sample_point_shadow(
                light.position,
                shadow_pos,
                light.range,
                light.point_shadow_index,
                light.shadow_bias,
            );
        } else if (light.shadow_layer_index >= 0) {
            if (light.light_type == 0u && light.cascade_count > 1u) {
                let view_pos = u_render_state.view_matrix * vec4<f32>(geometry.position, 1.0);
                let view_depth = -view_pos.z;

                var cascade_idx = light.cascade_count - 1u;
                if (view_depth < light.cascade_splits.x) {
                    cascade_idx = 0u;
                } else if (light.cascade_count > 1u && view_depth < light.cascade_splits.y) {
                    cascade_idx = 1u;
                } else if (light.cascade_count > 2u && view_depth < light.cascade_splits.z) {
                    cascade_idx = 2u;
                }

                let layer = light.shadow_layer_index + i32(cascade_idx);
                let matrix = light.shadow_matrices[cascade_idx];
                shadow = sample_shadow(matrix, layer, shadow_pos, light.shadow_bias);
            } else {
                shadow = sample_shadow(
                    light.shadow_matrices[0],
                    light.shadow_layer_index,
                    shadow_pos,
                    light.shadow_bias
                );
            }
        }

        punctual_light.color *= shadow;

        if (shadow <= 0.0001) {
            punctual_light.visible = false;
        }
    }
    $$ endif

    return punctual_light;
}


fn evaluate_punctual_lights(
    geometry: GeometricContext,
    material: SurfaceContext,
    reflected_light: ptr<function, ReflectedLight>,
    frag_coord: vec4<f32>
) {

    let grid_x = max(u_clustered_lighting.screen_dimensions.z, 1u);
    let grid_y = max(u_clustered_lighting.screen_dimensions.w, 1u);
    let grid_z = max(u_clustered_lighting.grid_dimensions.x, 1u);
    let tile_size_x = max(f32(u_clustered_lighting.grid_dimensions.z), 1.0);
    let tile_size_y = max(f32(u_clustered_lighting.grid_dimensions.w), 1.0);

    let cluster_x = min(u32(frag_coord.x / tile_size_x), grid_x - 1u);
    let cluster_y = min(u32(frag_coord.y / tile_size_y), grid_y - 1u);

    let view_pos = u_render_state.view_matrix * vec4<f32>(geometry.position, 1.0);
    let view_depth = max(-view_pos.z, u_clustered_lighting.depth_params.x);
    let cluster_z = min(
        u32(max(
            floor(log(view_depth) * u_clustered_lighting.depth_params.z
                + u_clustered_lighting.depth_params.w),
            0.0,
        )),
        grid_z - 1u,
    );

    let cluster_index = min(
        cluster_z * (grid_x * grid_y) + cluster_y * grid_x + cluster_x,
        max(u_clustered_lighting.grid_dimensions.y, 1u) - 1u,
    );
    let cluster = st_cluster_records[cluster_index];

    for (var i = 0u; i < cluster.count; i ++ ) {
        let light_index = st_cluster_light_indices[cluster.offset + i];
        let punctual_light = evaluate_light_visibility(light_index, geometry);
        if (punctual_light.visible) {
            RE_Direct( punctual_light, geometry, material, reflected_light );
        }
    }

}
