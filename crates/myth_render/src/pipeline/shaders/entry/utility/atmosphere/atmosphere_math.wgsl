// ============================================================================
// Hillaire 2020 Atmosphere — Pure Math Helpers
// ============================================================================

const PI: f32 = 3.14159265358979323846;
const TAU: f32 = 6.28318530717958647692;
const INV_ATAN: vec2<f32> = vec2<f32>(0.15915494, 0.31830989);

{$ include "entry/utility/atmosphere/transmittance_math" $}

fn direction_to_sky_view_uv(dir: vec3<f32>) -> vec2<f32> {
    let theta = asin(clamp(dir.y, -1.0, 1.0));

    var v: f32;
    if theta < 0.0 {
        let coord = sqrt(-theta / (PI * 0.5));
        v = 0.5 - 0.5 * coord;
    } else {
        let coord = sqrt(theta / (PI * 0.5));
        v = 0.5 + 0.5 * coord;
    }

    let phi = atan2(dir.x, dir.z);
    let u = (phi + PI) / TAU;
    return vec2<f32>(u, v);
}

fn sky_view_uv_to_direction(uv: vec2<f32>) -> vec3<f32> {
    let phi = uv.x * TAU - PI;

    let v = uv.y;
    var theta: f32;
    if v < 0.5 {
        let coord = 1.0 - 2.0 * v;
        theta = -(PI * 0.5) * coord * coord;
    } else {
        let coord = 2.0 * v - 1.0;
        theta = (PI * 0.5) * coord * coord;
    }

    let cos_theta = cos(theta);
    let sin_theta = sin(theta);

    return vec3<f32>(
        cos_theta * sin(phi),
        sin_theta,
        cos_theta * cos(phi)
    );
}

fn transmittance_lut_inv(
    uv: vec2<f32>,
    planet_radius: f32,
    atmosphere_radius: f32,
) -> vec2<f32> {
    let H = sqrt(max(
        0.0,
        atmosphere_radius * atmosphere_radius - planet_radius * planet_radius
    ));
    let rho = H * uv.y;
    let r = sqrt(rho * rho + planet_radius * planet_radius);
    let altitude = r - planet_radius;

    let d_min = atmosphere_radius - r;
    let d_max = rho + H;
    let d = d_min + uv.x * (d_max - d_min);

    let cos_zenith = clamp((H * H - rho * rho - d * d) / (2.0 * r * max(d, 1e-6)), -1.0, 1.0);
    return vec2<f32>(altitude, cos_zenith);
}

fn equirectangular_uv(dir: vec3<f32>) -> vec2<f32> {
    let eq_uv = vec2<f32>(
        atan2(dir.z, dir.x),
        acos(clamp(dir.y, -1.0, 1.0))
    );

    return vec2<f32>(
        eq_uv.x * INV_ATAN.x + 0.5,
        eq_uv.y * INV_ATAN.y
    );
}

fn rotate_about_axis(v: vec3<f32>, axis: vec3<f32>, angle: f32) -> vec3<f32> {
    let axis_length_sq = dot(axis, axis);
    if axis_length_sq <= 1e-8 {
        return v;
    }

    let n = axis * inverseSqrt(axis_length_sq);
    let s = sin(angle);
    let c = cos(angle);
    return v * c + cross(n, v) * s + n * dot(n, v) * (1.0 - c);
}