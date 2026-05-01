use std::f32::consts::TAU;

use glam::Vec3;
use wgpu::VertexFormat;

use crate::geometry::{Attribute, Geometry};

#[derive(Debug, Clone, Copy)]
pub struct TorusOptions {
    pub radius: f32,
    pub tube: f32,
    pub radial_segments: u32,
    pub tubular_segments: u32,
}

impl Default for TorusOptions {
    fn default() -> Self {
        Self {
            radius: 1.0,
            tube: 0.4,
            radial_segments: 16,
            tubular_segments: 32,
        }
    }
}

#[must_use]
pub fn create_torus(options: &TorusOptions) -> Geometry {
    let radial_segments = options.radial_segments.max(3);
    let tubular_segments = options.tubular_segments.max(3);

    let mut positions: Vec<[f32; 3]> = Vec::new();
    let mut normals: Vec<[f32; 3]> = Vec::new();
    let mut uvs: Vec<[f32; 2]> = Vec::new();
    let mut indices: Vec<u16> = Vec::new();

    for j in 0..=radial_segments {
        let v = j as f32 / radial_segments as f32 * TAU;
        let cos_v = v.cos();
        let sin_v = v.sin();

        for i in 0..=tubular_segments {
            let u = i as f32 / tubular_segments as f32 * TAU;
            let sin_u = u.sin();
            let cos_u = u.cos();

            let ring_radius = options.radius + options.tube * cos_v;
            let px = ring_radius * sin_u;
            let py = options.tube * sin_v;
            let pz = ring_radius * cos_u;
            positions.push([px, py, pz]);

            let center = Vec3::new(options.radius * sin_u, 0.0, options.radius * cos_u);
            let normal = (Vec3::new(px, py, pz) - center).normalize_or_zero();
            normals.push(normal.to_array());
            uvs.push([
                i as f32 / tubular_segments as f32,
                j as f32 / radial_segments as f32,
            ]);
        }
    }

    let stride = tubular_segments + 1;
    for j in 0..radial_segments {
        for i in 0..tubular_segments {
            let a = j * stride + i;
            let b = (j + 1) * stride + i;
            let c = b + 1;
            let d = a + 1;

            indices.extend_from_slice(&[a as u16, b as u16, d as u16]);
            indices.extend_from_slice(&[b as u16, c as u16, d as u16]);
        }
    }

    let mut geo = Geometry::new();
    geo.set_attribute(
        "position",
        Attribute::new_planar(&positions, VertexFormat::Float32x3),
    );
    geo.set_attribute(
        "normal",
        Attribute::new_planar(&normals, VertexFormat::Float32x3),
    );
    geo.set_attribute("uv", Attribute::new_planar(&uvs, VertexFormat::Float32x2));
    geo.set_indices(&indices);
    geo.compute_bounding_volume();
    geo
}
