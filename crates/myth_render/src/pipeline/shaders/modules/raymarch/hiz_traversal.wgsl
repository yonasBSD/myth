struct HiZTraceSegment {
    pixel_start: vec2<f32>,
    pixel_end: vec2<f32>,
    q0: vec3<f32>,
    q1: vec3<f32>,
    k0: f32,
    k1: f32,
};

struct HiZTraceConfig {
    screen_size: vec2<f32>,
    near_plane: f32,
    thickness: f32,
    mip_bias: f32,
    max_mip: u32,
    max_iterations: u32,
};

struct RaymarchResult {
    hit: bool,
    uv: vec2<f32>,
    depth: f32,
    iteration_count: u32,
};

fn hiz_trace_miss(iteration_count: u32) -> RaymarchResult {
    return RaymarchResult(false, vec2<f32>(0.0), 0.0, iteration_count);
}

fn hiz_depth_to_linear(near_plane: f32, depth: f32) -> f32 {
    return near_plane / max(depth, 0.0001);
}

fn hiz_ray_pixel(segment: HiZTraceSegment, t: f32) -> vec2<f32> {
    return mix(segment.pixel_start, segment.pixel_end, t);
}

fn hiz_ray_view_position(segment: HiZTraceSegment, t: f32) -> vec3<f32> {
    let q = mix(segment.q0, segment.q1, t);
    let k = mix(segment.k0, segment.k1, t);
    let safe_k = max(abs(k), 1e-6) * select(-1.0, 1.0, k >= 0.0);
    return q / safe_k;
}

fn hiz_ray_linear_depth(segment: HiZTraceSegment, t: f32, near_plane: f32) -> f32 {
    return max(-hiz_ray_view_position(segment, t).z, near_plane);
}

fn hiz_scaled_thickness(config: HiZTraceConfig, depth_linear: f32) -> f32 {
    return config.thickness * max(depth_linear, 1.0);
}

fn hiz_boundary_epsilon_t(pixel_span: f32, cell_size: f32) -> f32 {
    let boundary_push_pixels = max(0.25, cell_size * 0.01);
    return boundary_push_pixels / max(pixel_span, 1.0);
}

fn hiz_next_boundary_t(
    current_pixel: vec2<f32>,
    current_t: f32,
    inv_dir_pixels: vec2<f32>,
    cell_size: f32,
) -> f32 {
    let cell = floor(current_pixel / cell_size);
    let next_boundary = vec2<f32>(
        (cell.x + select(0.0, 1.0, inv_dir_pixels.x > 0.0)) * cell_size,
        (cell.y + select(0.0, 1.0, inv_dir_pixels.y > 0.0)) * cell_size,
    );

    let tx = current_t + (next_boundary.x - current_pixel.x) * inv_dir_pixels.x;

    let ty = current_t + (next_boundary.y - current_pixel.y) * inv_dir_pixels.y;

    return min(tx, ty);
}

fn hiz_refine_hit(
    segment: HiZTraceSegment,
    config: HiZTraceConfig,
    depth_texture: texture_depth_2d,
    start_t: f32,
    end_t: f32,
    iteration_count: u32,
) -> RaymarchResult {
    let max_coord = max(config.screen_size - vec2<f32>(1.0), vec2<f32>(0.0));
    let max_coord_i = vec2<i32>(max_coord);

    var left = start_t;
    var right = end_t;
    var found = false;
    var hit_uv = vec2<f32>(0.0);
    var hit_depth = 0.0;

    for (var refine = 0u; refine < 5u; refine++) {
        let mid = 0.5 * (left + right);
        let pixel = clamp(hiz_ray_pixel(segment, mid), vec2<f32>(0.0), max_coord);
        let coord = clamp(vec2<i32>(pixel), vec2<i32>(0), max_coord_i);
        let scene_depth = textureLoad(depth_texture, coord, 0);
        let ray_depth = hiz_ray_linear_depth(segment, mid, config.near_plane);

        if (scene_depth <= 0.0) {
            left = mid;
            continue;
        }

        let scene_linear = hiz_depth_to_linear(config.near_plane, scene_depth);
        if (ray_depth < scene_linear) {
            left = mid;
        } else {
            right = mid;
            hit_uv = (vec2<f32>(coord) + vec2<f32>(0.5)) / config.screen_size;
            hit_depth = ray_depth;
            found = true;
        }
    }

    if (!found) {
        return hiz_trace_miss(iteration_count);
    }

    return RaymarchResult(true, hit_uv, hit_depth, iteration_count);
}

fn trace_screen_space_ray_hiz(
    segment: HiZTraceSegment,
    config: HiZTraceConfig,
    hiz_texture: texture_2d<f32>,
    depth_texture: texture_depth_2d,
) -> RaymarchResult {
    let dir_pixels = segment.pixel_end - segment.pixel_start;
    let pixel_span = max(abs(dir_pixels.x), abs(dir_pixels.y));
    if (pixel_span < 1e-4) {
        return hiz_trace_miss(0u);
    }

    let span_safe = max(pixel_span, 1.0);
    let max_coord = max(config.screen_size - vec2<f32>(1.0), vec2<f32>(0.0));
    var current_mip = u32(clamp(
        floor(log2(span_safe)) + config.mip_bias,
        0.0,
        f32(config.max_mip),
    ));
    var current_t = hiz_boundary_epsilon_t(span_safe, exp2(f32(current_mip)));

    let inv_dir_pixels = select(vec2<f32>(1e30), 1.0 / dir_pixels, abs(dir_pixels) > vec2<f32>(1e-5));

    for (var iter = 0u; iter < config.max_iterations; iter++) {
        if (current_t >= 1.0) {
            return hiz_trace_miss(iter);
        }

        let pixel = hiz_ray_pixel(segment, current_t);
        if (pixel.x < 0.0 || pixel.x > max_coord.x || pixel.y < 0.0 || pixel.y > max_coord.y) {
            return hiz_trace_miss(iter);
        }

        // let cell_size = exp2(f32(current_mip));
        let cell_size = f32(1u << current_mip);
        // let mip_dims = vec2<i32>(textureDimensions(hiz_texture, i32(current_mip)));
        // let cell = clamp(
        //     vec2<i32>(floor(pixel / cell_size)),
        //     vec2<i32>(0),
        //     mip_dims - vec2<i32>(1),
        // );

        let cell = vec2<i32>(pixel) >> vec2<u32>(current_mip);

        let boundary_epsilon = hiz_boundary_epsilon_t(span_safe, cell_size);
        let boundary_t = min(
            hiz_next_boundary_t(pixel, current_t, inv_dir_pixels, cell_size) + boundary_epsilon,
            1.0,
        );
        let current_depth = hiz_ray_linear_depth(segment, current_t, config.near_plane);
        let boundary_depth = hiz_ray_linear_depth(segment, boundary_t, config.near_plane);
        let ray_min_depth = min(current_depth, boundary_depth);
        let ray_max_depth = max(current_depth, boundary_depth);

        let cell_depth = textureLoad(hiz_texture, cell, i32(current_mip)).r;
        let cell_linear = hiz_depth_to_linear(config.near_plane, cell_depth);
        let hit_candidate = cell_depth > 0.0 && ray_max_depth >= cell_linear;

        if (hit_candidate) {
            if (current_mip == 0u) {
                let thickness_limit = hiz_scaled_thickness(config, cell_linear);
                if (ray_min_depth > cell_linear + thickness_limit) {
                    current_t = boundary_t;
                    continue;
                }

                return hiz_refine_hit(
                    segment,
                    config,
                    depth_texture,
                    current_t,
                    boundary_t,
                    iter + 1u,
                );
            }

            current_mip -= 1u;
            continue;
        }

        current_t = boundary_t;
        current_mip = min(current_mip + 1u, config.max_mip);
    }

    return hiz_trace_miss(config.max_iterations);
}