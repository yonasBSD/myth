// ============================================================================
// Shared Atmosphere Transmittance Helpers
// ============================================================================
//
// Intentionally keeps only the LUT/ray helpers needed by both the atmosphere
// pipeline and forward lighting so material shaders do not inherit unrelated
// constants such as `PI`/`TAU` from `atmosphere_math.wgsl`.

fn ray_sphere_intersect(
    origin: vec3<f32>,
    direction: vec3<f32>,
    radius: f32,
) -> vec2<f32> {
    let a = dot(direction, direction);
    let b = 2.0 * dot(direction, origin);
    let c = dot(origin, origin) - radius * radius;
    let discriminant = b * b - 4.0 * a * c;
    if discriminant < 0.0 {
        return vec2<f32>(-1.0, -1.0);
    }

    let sqrt_discriminant = sqrt(discriminant);
    return vec2<f32>(
        (-b - sqrt_discriminant) / (2.0 * a),
        (-b + sqrt_discriminant) / (2.0 * a),
    );
}

fn transmittance_lut_uv(
    altitude: f32,
    cos_zenith: f32,
    planet_radius: f32,
    atmosphere_radius: f32,
) -> vec2<f32> {
    let safe_cos_zenith = clamp(cos_zenith, -1.0, 1.0);
    let atmosphere_height = sqrt(max(
        0.0,
        atmosphere_radius * atmosphere_radius - planet_radius * planet_radius,
    ));
    let rho = sqrt(max(
        0.0,
        (planet_radius + altitude) * (planet_radius + altitude)
            - planet_radius * planet_radius,
    ));
    let distance = ray_sphere_intersect(
        vec3<f32>(0.0, planet_radius + altitude, 0.0),
        vec3<f32>(
            0.0,
            safe_cos_zenith,
            sqrt(max(0.0, 1.0 - safe_cos_zenith * safe_cos_zenith)),
        ),
        atmosphere_radius,
    ).y;
    let distance_min = atmosphere_radius - planet_radius - altitude;
    let distance_max = rho + atmosphere_height;
    let x_mu = (distance - distance_min) / max(distance_max - distance_min, 1e-6);
    let x_r = rho / max(atmosphere_height, 1e-6);
    return vec2<f32>(x_mu, x_r);
}