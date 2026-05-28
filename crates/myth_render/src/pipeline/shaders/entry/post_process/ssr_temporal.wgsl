{$ include 'core/full_screen_vertex' $}

{{ struct_definitions }}
{{ binding_code }}
{{ scene_lighting_structs }}

@group(1) @binding(0) var t_raw_reflection: texture_2d<f32>;
@group(1) @binding(1) var t_raw_trace_data: texture_2d<f32>;
@group(1) @binding(2) var t_history_reflection: texture_2d<f32>;
@group(1) @binding(3) var t_depth: texture_depth_2d;
@group(1) @binding(4) var t_normal: texture_2d<f32>;
@group(1) @binding(5) var t_history_meta: texture_2d<f32>;
@group(1) @binding(6) var t_velocity: texture_2d<f32>;
@group(1) @binding(7) var t_material_data: texture_2d<f32>;
@group(1) @binding(8) var s_linear: sampler;
@group(1) @binding(9) var s_point: sampler;
@group(1) @binding(10) var<uniform> u_ssr: SsrUniforms;

struct TemporalOutput {
    @location(0) reflection: vec4<f32>,
    @location(1) history_meta: vec4<f32>,
};

struct HistorySample {
    color: vec3<f32>,
    confidence: f32,
    valid: bool,
};

struct ProjectedHistorySample {
    uv: vec2<f32>,
    expected_prev_linear: f32,
    valid: bool,
};

const HISTORY_META_HIT_TAG: f32 = -1.0;

fn saturate(v: f32) -> f32 {
    return clamp(v, 0.0, 1.0);
}

fn luminance(color: vec3<f32>) -> f32 {
    return dot(max(color, vec3<f32>(0.0)), vec3<f32>(0.2126, 0.7152, 0.0722));
}

fn perceptual_luma(color: vec3<f32>) -> f32 {
    return log2(1.0 + luminance(color));
}

fn unpack_view_normal(packed: vec4<f32>) -> vec3<f32> {
    let raw = packed.xyz * 2.0 - 1.0;
    return normalize(select(vec3<f32>(0.0, 0.0, 1.0), raw, dot(raw, raw) > 1e-5));
}

fn sign_not_zero(v: f32) -> f32 {
    return select(-1.0, 1.0, v >= 0.0);
}

fn oct_encode(normal: vec3<f32>) -> vec2<f32> {
    let inv_l1 = 1.0 / max(abs(normal.x) + abs(normal.y) + abs(normal.z), 1e-4);
    var encoded = normal.xy * inv_l1;

    if (normal.z < 0.0) {
        encoded = vec2<f32>(
            (1.0 - abs(encoded.y)) * sign_not_zero(encoded.x),
            (1.0 - abs(encoded.x)) * sign_not_zero(encoded.y)
        );
    }

    return encoded * 0.5 + 0.5;
}

fn oct_decode(encoded: vec2<f32>) -> vec3<f32> {
    let f = encoded * 2.0 - 1.0;
    var normal = vec3<f32>(f.x, f.y, 1.0 - abs(f.x) - abs(f.y));

    if (normal.z < 0.0) {
        let old_xy = normal.xy;
        normal.x = (1.0 - abs(old_xy.y)) * sign_not_zero(old_xy.x);
        normal.y = (1.0 - abs(old_xy.x)) * sign_not_zero(old_xy.y);
    }

    return normalize(normal);
}

fn linearize_depth(z: f32) -> f32 {
    return u_ssr.temporal_params.z / max(z, 0.0001);
}

fn jitter_uv_offset() -> vec2<f32> {
    return vec2<f32>(0.5, -0.5) * u_render_state.jitter;
}

fn jittered_to_unjittered_uv(uv: vec2<f32>) -> vec2<f32> {
    return uv - jitter_uv_offset();
}

fn unjittered_to_jittered_uv(uv: vec2<f32>) -> vec2<f32> {
    return uv + jitter_uv_offset();
}

fn prev_jitter_uv_offset() -> vec2<f32> {
    return vec2<f32>(0.5, -0.5) * u_render_state.prev_jitter;
}

fn jitter_history_uv(uv: vec2<f32>) -> vec2<f32> {
    return uv + prev_jitter_uv_offset() - jitter_uv_offset();
}

fn resolve_full_res_coord(pixel: vec2<i32>) -> vec2<i32> {
    let full_extent = vec2<i32>(i32(u_ssr.full_resolution.x), i32(u_ssr.full_resolution.y));
    let scale = select(vec2<i32>(1, 1), vec2<i32>(2, 2), u_ssr.denoise_params.y != 0u);
    return clamp(pixel * scale, vec2<i32>(0, 0), full_extent - vec2<i32>(1, 1));
}

fn full_res_coord_to_uv(coord: vec2<i32>) -> vec2<f32> {
    return (vec2<f32>(coord) + vec2<f32>(0.5, 0.5)) / u_ssr.full_resolution.xy;
}

fn reconstruct_view_position(uv: vec2<f32>, depth: f32) -> vec3<f32> {
    let unjittered_uv = jittered_to_unjittered_uv(uv);
    let ndc = vec4<f32>(
        unjittered_uv.x * 2.0 - 1.0,
        1.0 - unjittered_uv.y * 2.0,
        depth,
        1.0,
    );
    let view_pos = u_render_state.unjittered_projection_inverse * ndc;
    let safe_w = max(abs(view_pos.w), 1e-6) * sign(view_pos.w + 1e-6);
    return view_pos.xyz / safe_w;
}

fn project_current_hit_uv(world_pos: vec3<f32>) -> ProjectedHistorySample {
    let clip = u_render_state.unjittered_view_projection * vec4<f32>(world_pos, 1.0);
    if (clip.w <= 1e-5) {
        return ProjectedHistorySample(vec2<f32>(0.0), 0.0, false);
    }

    let ndc = clip.xyz / clip.w;
    let unjittered_uv = vec2<f32>(ndc.x * 0.5 + 0.5, 0.5 - ndc.y * 0.5);
    let jittered_uv = unjittered_to_jittered_uv(unjittered_uv);
    let valid = unjittered_uv.x >= 0.0 && unjittered_uv.x <= 1.0
        && unjittered_uv.y >= 0.0 && unjittered_uv.y <= 1.0
        && jittered_uv.x >= 0.0 && jittered_uv.x <= 1.0
        && jittered_uv.y >= 0.0 && jittered_uv.y <= 1.0;
    return ProjectedHistorySample(jittered_uv, 0.0, valid);
}

struct SurfaceSample {
    depth: f32,
    normal_packed: vec4<f32>,
    coord: vec2<i32>,
};

fn sample_surface_nearest(uv: vec2<f32>) -> SurfaceSample {
    let full_extent = vec2<i32>(i32(u_ssr.full_resolution.x), i32(u_ssr.full_resolution.y));
    let full_pixel = uv * vec2<f32>(full_extent) - vec2<f32>(0.5, 0.5);
    let coord = clamp(
        vec2<i32>(round(full_pixel)),
        vec2<i32>(0, 0),
        full_extent - vec2<i32>(1, 1)
    );
    return SurfaceSample(
        textureLoad(t_depth, coord, 0),
        textureLoad(t_normal, coord, 0),
        coord
    );
}

fn sample_surface_frontmost(uv: vec2<f32>) -> SurfaceSample {
    let full_extent = vec2<i32>(i32(u_ssr.full_resolution.x), i32(u_ssr.full_resolution.y));
    if (full_extent.x <= 1 || full_extent.y <= 1) {
        return sample_surface_nearest(uv);
    }

    let full_extent_f = vec2<f32>(full_extent);
    let full_pixel = uv * full_extent_f - vec2<f32>(0.5, 0.5);
    let base_coord = clamp(
        vec2<i32>(floor(full_pixel)),
        vec2<i32>(0, 0),
        full_extent - vec2<i32>(2, 2)
    );

    var best_depth = -1.0;
    var best_normal = vec4<f32>(0.0);
    var best_coord = base_coord;
    for (var y: i32 = 0; y <= 1; y++) {
        for (var x: i32 = 0; x <= 1; x++) {
            let coord = base_coord + vec2<i32>(x, y);
            let depth = textureLoad(t_depth, coord, 0);
            let normal = textureLoad(t_normal, coord, 0);
            if (normal.a < 0.5 || depth <= 0.0) {
                continue;
            }

            if (depth > best_depth) {
                best_depth = depth;
                best_normal = normal;
                best_coord = coord;
            }
        }
    }

    if (best_depth <= 0.0) {
        return sample_surface_nearest(uv);
    }

    return SurfaceSample(best_depth, best_normal, best_coord);
}

fn sample_surface_conservative(uv: vec2<f32>) -> SurfaceSample {
    let history_extent = vec2<i32>(textureDimensions(t_history_reflection));
    let full_extent = vec2<i32>(i32(u_ssr.full_resolution.x), i32(u_ssr.full_resolution.y));
    if (all(history_extent == full_extent)) {
        return sample_surface_nearest(uv);
    }

    let full_extent_f = vec2<f32>(full_extent);
    let full_pixel = uv * full_extent_f - vec2<f32>(0.5, 0.5);
    let base_coord = clamp(
        vec2<i32>(floor(full_pixel)),
        vec2<i32>(0, 0),
        full_extent - vec2<i32>(2, 2)
    );

    var best_depth = -1.0;
    var best_normal = vec4<f32>(0.0);
    var best_coord = base_coord;
    for (var y: i32 = 0; y <= 1; y++) {
        for (var x: i32 = 0; x <= 1; x++) {
            let coord = base_coord + vec2<i32>(x, y);
            let depth = textureLoad(t_depth, coord, 0);
            let normal = textureLoad(t_normal, coord, 0);
            if (normal.a < 0.5 || depth <= 0.0) {
                continue;
            }

            if (depth > best_depth) {
                best_depth = depth;
                best_normal = normal;
                best_coord = coord;
            }
        }
    }

    if (best_depth <= 0.0) {
        return sample_surface_nearest(uv);
    }

    return SurfaceSample(best_depth, best_normal, best_coord);
}

fn sample_dilated_velocity(full_res_coord: vec2<i32>) -> vec2<f32> {
    let full_extent = vec2<i32>(i32(u_ssr.full_resolution.x), i32(u_ssr.full_resolution.y));
    let max_coord = full_extent - vec2<i32>(1, 1);

    var closest_depth = textureLoad(t_depth, clamp(full_res_coord, vec2<i32>(0, 0), max_coord), 0);
    var closest_coord = clamp(full_res_coord, vec2<i32>(0, 0), max_coord);

    for (var y: i32 = -1; y <= 1; y++) {
        for (var x: i32 = -1; x <= 1; x++) {
            let coord = clamp(full_res_coord + vec2<i32>(x, y), vec2<i32>(0, 0), max_coord);
            let depth = textureLoad(t_depth, coord, 0);
            if (depth > closest_depth) {
                closest_depth = depth;
                closest_coord = coord;
            }
        }
    }

    return textureLoad(t_velocity, closest_coord, 0).rg;
}

fn get_safe_raw_reflection(pixel: vec2<i32>, extent: vec2<i32>) -> vec4<f32> {
    let coord = clamp(pixel, vec2<i32>(0, 0), extent - vec2<i32>(1, 1));
    let raw = textureLoad(t_raw_reflection, coord, 0);
    let luma_limit = u_ssr.temporal_params.y;
    let raw_luma = luminance(raw.rgb);
    if (luma_limit <= 0.0 || raw_luma <= luma_limit) {
        return raw;
    }

    return vec4<f32>(raw.rgb * (luma_limit / raw_luma), raw.a);
}

fn clip_towards_aabb_center(
    history_color: vec3<f32>,
    box_center: vec3<f32>,
    box_extent: vec3<f32>,
) -> vec3<f32> {
    let diff = history_color - box_center;
    let safe_extent = max(box_extent, vec3<f32>(1e-4));
    let ratio = max(
        abs(diff.x) / safe_extent.x,
        max(abs(diff.y) / safe_extent.y, abs(diff.z) / safe_extent.z)
    );

    if (ratio > 1.0) {
        return box_center + diff / ratio;
    }

    return history_color;
}

fn sample_valid_history(
    validation_world_normal: vec3<f32>,
    expected_prev_linear: f32,
    current_roughness: f32,
    history_uv: vec2<f32>,
    expect_hit_meta: bool,
) -> HistorySample {
    let history_extent = vec2<i32>(textureDimensions(t_history_reflection));
    let max_coord = history_extent - vec2<i32>(1, 1);
    let sample_pos = history_uv * vec2<f32>(history_extent) - vec2<f32>(0.5, 0.5);
    let base_coord = vec2<i32>(floor(sample_pos));
    let frac = fract(sample_pos);
    
    let roughness_ratio = clamp(current_roughness / max(u_ssr.shading_params.x, 1e-4), 0.0, 1.0);
    let hit_normal_threshold = mix(0.72, u_ssr.reprojection_params.y, roughness_ratio);
    // The hit-domain depth threshold must handle camera rotation: when the camera pitches
    // at a shallow angle, the ceiling hit world position changes significantly each frame,
    // causing a large clip-space depth delta even though the reflection is still valid.
    // Example: 3°/frame pitch at 5° camera angle → ~41% relative depth change, which
    // easily exceeds a purely parameter-driven threshold of ~33%.  A 0.45 floor ensures
    // history is accepted for moderate camera rotation (≲4°/frame at shallow angles) while
    // the AABB neighbourhood clipping corrects any colour inaccuracy from stale content.
    let hit_depth_threshold = max(
        u_ssr.reprojection_params.z * mix(2.8, 1.4, roughness_ratio),
        0.45
    );
    let normal_threshold = select(u_ssr.reprojection_params.y, hit_normal_threshold, expect_hit_meta);
    let depth_threshold = select(u_ssr.reprojection_params.z, hit_depth_threshold, expect_hit_meta);

    var color_sum = vec3<f32>(0.0);
    var confidence_sum = 0.0;
    var weight_sum = 0.0;

    for (var y: i32 = 0; y <= 1; y++) {
        for (var x: i32 = 0; x <= 1; x++) {
            let coord = clamp(base_coord + vec2<i32>(x, y), vec2<i32>(0, 0), max_coord);
            let hist_meta = textureLoad(t_history_meta, coord, 0);

            let hist_normal = oct_decode(hist_meta.xy);
            let hist_linear = hist_meta.z;
            let is_history_hit = hist_meta.w < 0.0;

            var is_valid = false;
            // When accepting hit-tagged history in surface domain, reduce confidence so
            // the old reflection fades over a few frames rather than snapping to black.
            var fade_factor = 1.0;

            if (expect_hit_meta) {
                // For hit-domain history, let depth and normal decide. Do not hard-reject
                // surface-tagged pixels solely on the tag: near reflection edges the 2×2
                // neighbourhood will contain mixed tags and the depth/normal check is
                // sufficient to discriminate stale surface history from valid hit history.
                // let depth_ok = abs(expected_prev_linear - hist_linear) <= depth_threshold * max(expected_prev_linear, 1.0);
                // let normal_ok = dot(validation_world_normal, hist_normal) >= normal_threshold;
                // is_valid = depth_ok && normal_ok;

                if (is_history_hit) {
                    // 放宽 1.5 倍的深度容忍度，用来吸收 GGX 粗糙度带来的射线散射噪点
                    let depth_ok = abs(expected_prev_linear - hist_linear) <= depth_threshold * max(expected_prev_linear, 1.0) * 1.5; 
                    // 直接废除 normal_ok 验证！把可能出现的残影完全交给后续的 AABB 方差裁剪处理
                    is_valid = depth_ok; 
                }
            } else {
                if (!is_history_hit) {
                    let depth_ok = abs(expected_prev_linear - hist_linear) <= depth_threshold * max(expected_prev_linear, 1.0);
                    let normal_ok = dot(validation_world_normal, hist_normal) >= normal_threshold;
                    let roughness_ok = abs(current_roughness - hist_meta.w) <= u_ssr.reprojection_params.w;
                    is_valid = depth_ok && normal_ok && roughness_ok;
                } else {
                    // Surface domain but history is hit-tagged: this pixel just exited the
                    // reflection zone (camera pitched away).  Rather than rejecting and
                    // snapping the output to black in a single frame, accept with a reduced
                    // confidence multiplier so the reflection fades out gracefully.
                    // Only the surface normal needs to agree (the floor didn't move).
                    is_valid = dot(validation_world_normal, hist_normal) >= normal_threshold;
                    fade_factor = 0.45;
                }
            }

            if (!is_valid) {
                continue;
            }

            let hist_reflection = textureLoad(t_history_reflection, coord, 0);
            if (hist_reflection.a <= 1e-4) {
                continue;
            }

            let bilinear_weight_x = select(1.0 - frac.x, frac.x, x == 1);
            let bilinear_weight_y = select(1.0 - frac.y, frac.y, y == 1);
            let weight = bilinear_weight_x * bilinear_weight_y;

            color_sum += hist_reflection.rgb * weight;
            confidence_sum += hist_reflection.a * weight * fade_factor;
            weight_sum += weight;
        }
    }

    if (weight_sum <= 1e-4) {
        return HistorySample(vec3<f32>(0.0), 0.0, false);
    }

    return HistorySample(color_sum / weight_sum, confidence_sum / weight_sum, true);
}

@fragment
fn fs_main(in: VertexOutput) -> TemporalOutput {
    var out: TemporalOutput;
    out.reflection = vec4<f32>(0.0);
    out.history_meta = vec4<f32>(0.0);

    let pixel = vec2<i32>(in.position.xy);
    let raw_extent = vec2<i32>(textureDimensions(t_raw_reflection));
    let full_res_coord = resolve_full_res_coord(pixel);
    let current_depth = textureLoad(t_depth, full_res_coord, 0);
    let current_normal_packed = textureLoad(t_normal, full_res_coord, 0);
    if (current_depth <= 0.0 || current_normal_packed.a < 0.5) {
        return out;
    }

    let current_material = textureLoad(t_material_data, full_res_coord, 0);
    let current_roughness = current_material.a;
    let current_normal = unpack_view_normal(current_normal_packed);
    let surface_uv = full_res_coord_to_uv(full_res_coord);
    // surface_uv is the unjittered pixel-centre UV. reconstruct_view_position
    // internally strips jitter, so pass the jittered version so the correction
    // cancels cleanly (no-op when TAA is off).
    let current_view_pos = reconstruct_view_position(unjittered_to_jittered_uv(surface_uv), current_depth);
    let view_rot = mat3x3<f32>(
        u_render_state.view_matrix[0].xyz,
        u_render_state.view_matrix[1].xyz,
        u_render_state.view_matrix[2].xyz,
    );
    let current_world_pos = transpose(view_rot) * current_view_pos + u_render_state.camera_position;
    let current_clip = u_render_state.unjittered_view_projection * vec4<f32>(current_world_pos, 1.0);
    let current_linear = current_clip.w;
    let current_world_normal = normalize(transpose(view_rot) * current_normal);
    var validation_world_normal = current_world_normal;
    var validation_roughness = current_roughness;
    var expect_hit_meta = false;
    out.history_meta = vec4<f32>(oct_encode(current_world_normal), current_linear, current_roughness);

    if (current_roughness > u_ssr.shading_params.x) {
        return out;
    }

    let current_raw = get_safe_raw_reflection(pixel, raw_extent);
    let raw_trace = textureLoad(t_raw_trace_data, pixel, 0);

    let stable_view_dir = normalize(-current_view_pos);
    let stable_ray_dir_view = reflect(-stable_view_dir, current_normal);
    let stable_ray_dir_world = normalize(transpose(view_rot) * stable_ray_dir_view);

    var stable_virtual_world_pos = current_world_pos;

    // let stable_hit_world_pos = current_world_pos + stable_ray_dir_world * max(raw_trace.w, 0.001);

    if (raw_trace.w > 0.0) {

        let surface_to_hit = raw_trace.xyz - current_world_pos;
        let stable_travel = max(dot(surface_to_hit, stable_ray_dir_world), 0.01);

        stable_virtual_world_pos = current_world_pos + stable_ray_dir_world * stable_travel;

        let exact_hit_clip = u_render_state.unjittered_view_projection * vec4<f32>(stable_virtual_world_pos, 1.0);
    
        validation_world_normal = current_world_normal;
        expect_hit_meta = true;
        out.history_meta = vec4<f32>(
            oct_encode(validation_world_normal),
            exact_hit_clip.w,
            HISTORY_META_HIT_TAG
        );

        // let exact_hit_clip = u_render_state.unjittered_view_projection * vec4<f32>(raw_trace.xyz, 1.0);
        // let view_dir_world = normalize(current_world_pos - u_render_state.camera_position);
        // let virtual_world_pos = current_world_pos + view_dir_world * raw_trace.w; // raw_trace.w 即为 travel

        // let exact_hit_clip = u_render_state.unjittered_view_projection * vec4<f32>(virtual_world_pos, 1.0);

        // // let exact_hit_clip = u_render_state.unjittered_view_projection * vec4<f32>(stable_hit_world_pos, 1.0);
        // validation_world_normal = current_world_normal;
        // expect_hit_meta = true;
        // out.history_meta = vec4<f32>(
        //     oct_encode(validation_world_normal),
        //     exact_hit_clip.w,
        //     HISTORY_META_HIT_TAG
        // );
    }

    var moment1 = vec3<f32>(0.0);
    var moment2 = vec3<f32>(0.0);
    var valid_weight = 0.0;
    for (var y: i32 = -1; y <= 1; y++) {
        for (var x: i32 = -1; x <= 1; x++) {
            let sample_coord = clamp(pixel + vec2<i32>(x, y), vec2<i32>(0, 0), raw_extent - vec2<i32>(1, 1));
            let sample_value = get_safe_raw_reflection(sample_coord, raw_extent);
            if (sample_value.a <= 1e-4) {
                continue;
            }

            moment1 += sample_value.rgb;
            moment2 += sample_value.rgb * sample_value.rgb;
            valid_weight += 1.0;
        }
    }

    var mean = current_raw.rgb;
    var std_dev = vec3<f32>(0.0);
    if (valid_weight > 0.0) {
        mean = moment1 / valid_weight;
        let variance = max(moment2 / valid_weight - mean * mean, vec3<f32>(0.0));
        // Add a small absolute variance floor so the AABB never collapses to a
        // point at reflection edges where only 1-2 of the 9 neighbourhood pixels
        // have a valid hit.  Without this the AABB box can be far too tight and
        // the temporal clipper aggressively rejects any history, producing single-
        // pixel edge flicker during camera motion.
        std_dev = sqrt(variance) + max(mean * 0.05, vec3<f32>(0.005));
    }

    let camera_cut = (u_ssr.frame_params.w & 2u) != 0u;

    var reflection = current_raw;
    var accepted_history = false;

    if (!camera_cut && (u_ssr.frame_params.w & 1u) != 0u) {
        let velocity = sample_dilated_velocity(full_res_coord);
        let surface_history_uv = jitter_history_uv(surface_uv - velocity);
        let prev_surface_clip = u_render_state.prev_unjittered_view_projection * vec4<f32>(current_world_pos, 1.0);
        let surface_history_uv_sample = ProjectedHistorySample(
            surface_history_uv,
            prev_surface_clip.w,
            prev_surface_clip.w > 1e-5
                && surface_history_uv.x >= 0.0 && surface_history_uv.x <= 1.0
                && surface_history_uv.y >= 0.0 && surface_history_uv.y <= 1.0
        );

        var history_uv_sample = ProjectedHistorySample(vec2<f32>(0.0), 0.0, false);
        var history_validation_normal = current_world_normal;
        var history_validation_roughness = current_roughness;
        var history_expect_hit_meta = false;
        var used_hit_history = false;

        if (expect_hit_meta) {
            // The history buffer is indexed by SURFACE PIXEL screen coordinates —
            // each texel stores the accumulated reflection for the floor pixel that
            // was at that screen position in the previous frame.  The correct history
            // UV is therefore the surface pixel's own reprojection UV
            // (surface_history_uv), NOT the screen position of the ceiling hit point.
            //
            // Using the ceiling hit's screen UV (prev_virtual_clip) was wrong:
            //   • Translation: by coincidence the error was small for near-overhead cameras.
            //   • Rotation: the ceiling hit moves dramatically across the screen while
            //     the floor pixel moves predictably → wrong UV → history miss → jitter.
            //
            // prev_virtual_clip.w is still used as the expected depth for the depth-based
            // validation in sample_valid_history, ensuring we only accept history that
            // came from a similar ceiling area.
            let prev_virtual_clip = u_render_state.prev_unjittered_view_projection
                * vec4<f32>(stable_virtual_world_pos, 1.0);

            if (surface_history_uv_sample.valid && prev_virtual_clip.w > 1e-5) {
                history_uv_sample = ProjectedHistorySample(
                    surface_history_uv_sample.uv,  // floor pixel's own reprojection UV
                    prev_virtual_clip.w,            // hit depth for depth-based validation
                    true,
                );
                history_validation_normal = validation_world_normal;
                history_validation_roughness = validation_roughness;
                history_expect_hit_meta = true;
                used_hit_history = true;
            }
        } else {
            history_uv_sample = surface_history_uv_sample;
        }

        var history = HistorySample(vec3<f32>(0.0), 0.0, false);
        if (history_uv_sample.valid) {
            history = sample_valid_history(
                history_validation_normal,
                history_uv_sample.expected_prev_linear,
                history_validation_roughness,
                history_uv_sample.uv,
                history_expect_hit_meta,
            );
        }

        if (history.valid) {
                let roughness_ratio = clamp(
                    current_roughness / max(u_ssr.shading_params.x, 1e-4),
                    0.0,
                    1.0
                );
                var current_weight = mix(
                    u_ssr.reprojection_params.x,
                    max(u_ssr.reprojection_params.x * 0.45, 0.04),
                    roughness_ratio
                );
                var clip_scale = 1.0;
                if (used_hit_history) {
                    // Hit-domain: surface pixel's own UV is used (stable under rotation),
                    // but the reflection content is view-dependent.  Allow moderate AABB
                    // room so small view-direction changes between frames are absorbed, and
                    // use a slightly higher current-frame weight to clear bad history fast.
                    current_weight = max(current_weight, 0.14);
                    clip_scale = mix(1.8, 1.0, roughness_ratio);
                }

                let box_extent = max(
                    std_dev * u_ssr.temporal_params.x * clip_scale,
                    vec3<f32>(1e-4)
                );
                let clipped_history = clip_towards_aabb_center(history.color, mean, box_extent);
                let history_confidence = history.confidence;
                if (current_raw.a > 1e-4) {
                    reflection = vec4<f32>(
                        mix(clipped_history, current_raw.rgb, current_weight),
                        mix(history_confidence, current_raw.a, current_weight)
                    );
                } else {
                    reflection = vec4<f32>(
                        clipped_history,
                        history_confidence * 0.85
                    );
                }
                accepted_history = true;
        }
    }

    if (!accepted_history && current_raw.a <= 1e-4) {
        reflection = vec4<f32>(0.0);
    } else if (!accepted_history && valid_weight >= 3.0) {
        // History rejected but we have a valid trace hit.  Replace the noisy single
        // sample with the spatial mean of valid neighbourhood hits — this reduces the
        // per-pixel stochastic noise that is most visible as horizontal stripes at the
        // reflection boundary.  The confidence (alpha) is kept from the original trace
        // so the merge pass can still fade the reflection gracefully.
        reflection = vec4<f32>(mean, current_raw.a);
    }

    out.reflection = reflection;
    return out;
}