// Debug View — visualise intermediate RDG textures.
//
// A full-screen post-process pass that remaps arbitrary texture formats
// into a displayable [0, 1] RGB range.  The `view_mode` uniform selects
// the mapping strategy so a single pipeline can handle depth, normals,
// single-channel occlusion, and standard colour buffers alike.

{$ include 'core/full_screen_vertex' $}
{{ clustered_lighting_structs }}

struct DebugUniforms {
    view_mode: u32,
    custom_scale: f32,
    z_near: f32,
    z_far: f32,
};

// Group 0 (static): sampler + uniforms — owned by the Feature.
@group(0) @binding(0) var debug_sampler: sampler;
@group(0) @binding(1) var<uniform> uniforms: DebugUniforms;

// Group 1 (transient): source texture — rebuilt each frame.
$$ if IS_DEPTH
@group(1) @binding(0) var debug_texture: texture_depth_2d;
$$ else
@group(1) @binding(0) var debug_texture: texture_2d<f32>;
$$ endif
@group(1) @binding(1) var<uniform> u_clustered_lighting: ClusteredLightingParams;
@group(1) @binding(2) var<storage, read> st_cluster_records: array<ClusterRecord>;

fn heatmap_color(t: f32) -> vec3<f32> {
    let value = clamp(t, 0.0, 1.0);
    if (value < 0.33) {
        let local = value / 0.33;
        return mix(vec3<f32>(0.04, 0.08, 0.24), vec3<f32>(0.00, 0.72, 0.96), local);
    }
    if (value < 0.66) {
        let local = (value - 0.33) / 0.33;
        return mix(vec3<f32>(0.00, 0.72, 0.96), vec3<f32>(0.98, 0.86, 0.18), local);
    }
    let local = (value - 0.66) / 0.34;
    return mix(vec3<f32>(0.98, 0.86, 0.18), vec3<f32>(0.96, 0.18, 0.12), local);
}

fn tonemap_debug(color: vec3<f32>, exposure: f32) -> vec3<f32> {
    let hdr = max(color * max(exposure, 0.001), vec3<f32>(0.0));
    let mapped = hdr / (vec3<f32>(1.0) + hdr);
    return pow(mapped, vec3<f32>(1.0 / 2.2));
}

@fragment
fn fs_main(in: VertexOutput) -> @location(0) vec4<f32> {
    $$ if IS_DEPTH
    let depth_val = textureSampleLevel(debug_texture, debug_sampler, in.uv, 0i);
    let tex_color = vec4<f32>(depth_val, depth_val, depth_val, 1.0);
    $$ else
    let tex_color = textureSampleLevel(debug_texture, debug_sampler, in.uv, 0.0);
    $$ endif

    switch uniforms.view_mode {
        // Mode 1: SSAO / Roughness / Metallic
        case 1u: {
            return vec4<f32>(tex_color.rrr, 1.0);
        }
        // Mode 2: World/View Normals
        case 2u: {
            return vec4<f32>(tex_color.rgb * 0.5 + 0.5, 1.0);
        }
        // Mode 3: Velocity / Motion Vectors
        case 3u: {
            let vel = tex_color.xy * uniforms.custom_scale;
            let abs_vel = abs(vel);
            let positive_vel = max(vel, vec2<f32>(0.0));
            let negative_vel = max(-vel, vec2<f32>(0.0));
            
            let color = vec3<f32>(
                positive_vel.x + negative_vel.y, // R
                positive_vel.y + negative_vel.x, // G
                negative_vel.x + negative_vel.y  // B
            );

            return vec4<f32>(color + vec3<f32>(length(vel)), 1.0);
        }
        // Mode 4: Depth (Reverse-Z)
        case 4u: {
            let ndc_z = tex_color.r; 
            let linear_depth = (uniforms.z_near * uniforms.z_far) / 
                               (uniforms.z_near + ndc_z * (uniforms.z_far - uniforms.z_near));
            
            let display_depth = linear_depth / uniforms.z_far;
            
            let fract_depth = fract(display_depth * uniforms.custom_scale);

            return vec4<f32>(vec3<f32>(display_depth * 0.8 + fract_depth * 0.2), 1.0);
        }
        // Mode 5: Clustered lighting heatmap
        case 5u: {
            let clustered_enabled = (u_clustered_lighting.budget.z & 1u) != 0u;
            if (!clustered_enabled) {
                return vec4<f32>(0.0, 0.0, 0.0, 1.0);
            }

            $$ if IS_DEPTH
            let depth_ndc = textureSampleLevel(debug_texture, debug_sampler, in.uv, 0i);
            if (depth_ndc <= 0.0) {
                return vec4<f32>(0.0, 0.0, 0.0, 1.0);
            }

            let screen_size = vec2<f32>(
                max(f32(u_clustered_lighting.screen_dimensions.x), 1.0),
                max(f32(u_clustered_lighting.screen_dimensions.y), 1.0),
            );
            let pixel = clamp(in.uv * screen_size, vec2<f32>(0.0), screen_size - vec2<f32>(1.0));
            let grid_x = max(u_clustered_lighting.screen_dimensions.z, 1u);
            let grid_y = max(u_clustered_lighting.screen_dimensions.w, 1u);
            let grid_z = max(u_clustered_lighting.grid_dimensions.x, 1u);
            let tile_size_x = max(f32(u_clustered_lighting.grid_dimensions.z), 1.0);
            let tile_size_y = max(f32(u_clustered_lighting.grid_dimensions.w), 1.0);

            let cluster_x = min(u32(pixel.x / tile_size_x), grid_x - 1u);
            let cluster_y = min(u32(pixel.y / tile_size_y), grid_y - 1u);
            let linear_depth = clamp(
                u_clustered_lighting.depth_params.x / max(depth_ndc, 0.00001),
                u_clustered_lighting.depth_params.x,
                u_clustered_lighting.depth_params.y,
            );
            let cluster_z = min(
                u32(max(
                    floor(log(linear_depth) * u_clustered_lighting.depth_params.z
                        + u_clustered_lighting.depth_params.w),
                    0.0,
                )),
                grid_z - 1u,
            );

            let cluster_index = min(
                cluster_z * (grid_x * grid_y) + cluster_y * grid_x + cluster_x,
                max(u_clustered_lighting.grid_dimensions.y, 1u) - 1u,
            );
            let cluster_count = f32(st_cluster_records[cluster_index].count);
            let cluster_budget = max(f32(u_clustered_lighting.budget.x), 1.0);
            let normalized = cluster_count / cluster_budget;
            var color = heatmap_color(normalized);

            let grid = abs(fract(pixel / vec2<f32>(tile_size_x, tile_size_y)) - 0.5);
            let grid_line = 1.0
                - smoothstep(0.46, 0.5, max(grid.x, grid.y));
            color = mix(color, vec3<f32>(0.0), grid_line * 0.35);

            return vec4<f32>(color, 1.0);
            $$ else
            return vec4<f32>(0.0, 0.0, 0.0, 1.0);
            $$ endif
        }
        // Mode 6: SSGI raw indirect radiance
        case 6u: {
            return vec4<f32>(tonemap_debug(tex_color.rgb, uniforms.custom_scale), 1.0);
        }
        // Mode 7: SSGI denoised indirect radiance + accumulation hint
        case 7u: {
            let mapped = tonemap_debug(tex_color.rgb, uniforms.custom_scale);
            let confidence = clamp(tex_color.a / 8.0, 0.0, 1.0);
            let overlay = mix(vec3<f32>(0.08, 0.16, 0.44), vec3<f32>(0.28, 0.96, 0.36), confidence);
            return vec4<f32>(mix(mapped, overlay, 0.18), 1.0);
        }
        // Mode 8: SSR raw reflection hit confidence
        case 8u: {
            let mapped = tonemap_debug(tex_color.rgb, uniforms.custom_scale);
            let confidence = clamp(tex_color.a, 0.0, 1.0);
            let overlay = mix(vec3<f32>(0.10, 0.06, 0.22), vec3<f32>(0.94, 0.58, 0.18), confidence);
            return vec4<f32>(mix(mapped, overlay, 0.16), 1.0);
        }
        // Mode 9: SSR resolved reflection confidence
        case 9u: {
            let mapped = tonemap_debug(tex_color.rgb, uniforms.custom_scale);
            let confidence = clamp(tex_color.a, 0.0, 1.0);
            let overlay = mix(vec3<f32>(0.05, 0.10, 0.20), vec3<f32>(0.30, 0.92, 0.86), confidence);
            return vec4<f32>(mix(mapped, overlay, 0.18), 1.0);
        }
        // Default: colour pass-through
        default: {
            return vec4<f32>(tex_color.rgb, 1.0);
        }
    }
}
