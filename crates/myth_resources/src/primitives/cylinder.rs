use std::f32::consts::TAU;

use glam::Vec3;
use wgpu::VertexFormat;

use crate::geometry::{Attribute, Geometry};

#[derive(Debug, Clone, Copy)]
pub struct CylinderOptions {
    pub radius_top: f32,
    pub radius_bottom: f32,
    pub height: f32,
    pub radial_segments: u32,
    pub height_segments: u32,
    pub open_ended: bool,
}

impl Default for CylinderOptions {
    fn default() -> Self {
        Self {
            radius_top: 1.0,
            radius_bottom: 1.0,
            height: 1.0,
            radial_segments: 32,
            height_segments: 1,
            open_ended: false,
        }
    }
}

#[must_use]
pub fn create_cylinder(options: &CylinderOptions) -> Geometry {
    let radial_segments = options.radial_segments.max(3);
    let height_segments = options.height_segments.max(1);
    let half_height = options.height * 0.5;
    let slope = if options.height.abs() > f32::EPSILON {
        (options.radius_bottom - options.radius_top) / options.height
    } else {
        0.0
    };

    let mut positions: Vec<[f32; 3]> = Vec::new();
    let mut normals: Vec<[f32; 3]> = Vec::new();
    let mut uvs: Vec<[f32; 2]> = Vec::new();
    let mut indices: Vec<u16> = Vec::new();

    for y in 0..=height_segments {
        let v = y as f32 / height_segments as f32;
        let radius = options.radius_top + (options.radius_bottom - options.radius_top) * v;
        let py = half_height - v * options.height;

        for x in 0..=radial_segments {
            let u = x as f32 / radial_segments as f32;
            let theta = u * TAU;
            let sin_theta = theta.sin();
            let cos_theta = theta.cos();

            positions.push([radius * sin_theta, py, radius * cos_theta]);

            let normal = Vec3::new(sin_theta, slope, cos_theta).normalize_or_zero();
            normals.push(normal.to_array());
            uvs.push([u, 1.0 - v]);
        }
    }

    let stride = radial_segments + 1;
    for y in 0..height_segments {
        for x in 0..radial_segments {
            let a = y * stride + x;
            let b = (y + 1) * stride + x;
            let c = b + 1;
            let d = a + 1;

            indices.extend_from_slice(&[a as u16, b as u16, d as u16]);
            indices.extend_from_slice(&[b as u16, c as u16, d as u16]);
        }
    }

    if !options.open_ended {
        generate_cap(
            true,
            options.radius_top,
            half_height,
            radial_segments,
            &mut positions,
            &mut normals,
            &mut uvs,
            &mut indices,
        );
        generate_cap(
            false,
            options.radius_bottom,
            -half_height,
            radial_segments,
            &mut positions,
            &mut normals,
            &mut uvs,
            &mut indices,
        );
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

fn generate_cap(
    top: bool,
    radius: f32,
    y: f32,
    radial_segments: u32,
    positions: &mut Vec<[f32; 3]>,
    normals: &mut Vec<[f32; 3]>,
    uvs: &mut Vec<[f32; 2]>,
    indices: &mut Vec<u16>,
) {
    if radius <= 0.0 {
        return;
    }

    let normal_y = if top { 1.0 } else { -1.0 };
    let center_index = positions.len() as u32;
    positions.push([0.0, y, 0.0]);
    normals.push([0.0, normal_y, 0.0]);
    uvs.push([0.5, 0.5]);

    let ring_start = positions.len() as u32;
    for x in 0..=radial_segments {
        let u = x as f32 / radial_segments as f32;
        let theta = u * TAU;
        let sin_theta = theta.sin();
        let cos_theta = theta.cos();

        positions.push([radius * sin_theta, y, radius * cos_theta]);
        normals.push([0.0, normal_y, 0.0]);
        uvs.push([sin_theta * 0.5 + 0.5, cos_theta * 0.5 + 0.5]);
    }

    for x in 0..radial_segments {
        let current = ring_start + x;
        let next = current + 1;
        if top {
            indices.extend_from_slice(&[center_index as u16, current as u16, next as u16]);
        } else {
            indices.extend_from_slice(&[center_index as u16, next as u16, current as u16]);
        }
    }
}
