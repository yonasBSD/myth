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

fn debug_world_hit_grid(world_pos: vec3<f32>) -> vec3<f32> {
    let scaled = world_pos * 0.75;
    let base = fract(vec3<f32>(
        dot(scaled, vec3<f32>(0.1031, 0.11369, 0.13787)),
        dot(scaled, vec3<f32>(0.2695, 0.1833, 0.2461)),
        dot(scaled, vec3<f32>(0.2473, 0.2921, 0.1737))
    ));
    let cell = abs(fract(scaled) - vec3<f32>(0.5));
    let line = 1.0 - smoothstep(0.46, 0.5, min(min(cell.x, cell.y), cell.z));
    return mix(base, vec3<f32>(1.0), line * 0.85);
}

fn debug_trace_texel_diagnostic(diag: vec4<f32>) -> vec3<f32> {
    let delta_pixels = diag.xy;
    let error_pixels = diag.z;
    let direction = clamp(delta_pixels * 0.5 + vec2<f32>(0.5, 0.5), vec2<f32>(0.0), vec2<f32>(1.0));
    let magnitude = clamp(error_pixels / 1.5, 0.0, 1.0);
    let axis_emphasis = clamp(abs(delta_pixels) / 0.5, vec2<f32>(0.0), vec2<f32>(1.0));

    let direction_color = vec3<f32>(direction.x, direction.y, 1.0 - 0.5 * (direction.x + direction.y));
    let magnitude_color = heatmap_color(magnitude);
    let axis_overlay = vec3<f32>(axis_emphasis.x, axis_emphasis.y, max(axis_emphasis.x, axis_emphasis.y));

    var color = mix(vec3<f32>(0.02, 0.04, 0.08), magnitude_color, magnitude);
    color = mix(color, direction_color, 0.45);
    color = mix(color, axis_overlay, 0.20 * step(0.02, error_pixels));
    return color;
}

fn debug_trace_state(diag: vec4<f32>) -> vec3<f32> {
    let stage_value = diag.w;
    let stage = u32(floor(stage_value + 1e-3));
    let near_clip_active = fract(stage_value) > 0.25;

    var color = vec3<f32>(0.0);
    switch stage {
        case 1u: {
            color = vec3<f32>(0.18, 0.18, 0.18);
        }
        case 2u: {
            color = vec3<f32>(0.86, 0.16, 0.68);
        }
        case 3u: {
            color = vec3<f32>(0.14, 0.86, 0.92);
        }
        case 4u: {
            color = vec3<f32>(0.94, 0.90, 0.24);
        }
        case 5u: {
            color = vec3<f32>(0.74, 0.22, 0.92);
        }
        case 6u: {
            color = vec3<f32>(0.18, 0.50, 1.0);
        }
        case 7u: {
            color = vec3<f32>(1.0, 0.58, 0.12);
        }
        case 8u: {
            color = vec3<f32>(1.0, 0.78, 0.22);
        }
        case 9u: {
            color = vec3<f32>(1.0, 0.22, 0.32);
        }
        case 10u: {
            color = vec3<f32>(0.96, 0.88, 0.18);
        }
        case 11u: {
            color = vec3<f32>(0.20, 0.94, 0.36);
        }
        case 12u: {
            color = vec3<f32>(0.96, 0.36, 0.78);
        }
        default: {
            color = vec3<f32>(0.0);
        }
    }

    if (near_clip_active) {
        color = mix(color, vec3<f32>(0.18, 0.96, 1.0), 0.45);
    }

    return color;
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
        // Mode 8: SSR raw reflection confidence
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
        // Mode 10: SSR trace consistency diagnostic
        case 10u: {
            if (tex_color.a <= 1e-4) {
                return vec4<f32>(0.0, 0.0, 0.0, 1.0);
            }
            return vec4<f32>(debug_trace_texel_diagnostic(tex_color), 1.0);
        }
        // Mode 11: SSR trace state diagnostic
        case 11u: {
            if (tex_color.a <= 1e-4) {
                return vec4<f32>(0.0, 0.0, 0.0, 1.0);
            }
            return vec4<f32>(debug_trace_state(tex_color), 1.0);
        }
        // Default: colour pass-through
        default: {
            return vec4<f32>(tex_color.rgb, 1.0);
        }
    }
}
