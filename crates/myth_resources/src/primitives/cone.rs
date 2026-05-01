use crate::geometry::Geometry;

use super::cylinder::{CylinderOptions, create_cylinder};

#[derive(Debug, Clone, Copy)]
pub struct ConeOptions {
    pub radius: f32,
    pub height: f32,
    pub radial_segments: u32,
    pub height_segments: u32,
    pub open_ended: bool,
}

impl Default for ConeOptions {
    fn default() -> Self {
        Self {
            radius: 1.0,
            height: 1.0,
            radial_segments: 32,
            height_segments: 1,
            open_ended: false,
        }
    }
}

#[must_use]
pub fn create_cone(options: &ConeOptions) -> Geometry {
    create_cylinder(&CylinderOptions {
        radius_top: 0.0,
        radius_bottom: options.radius,
        height: options.height,
        radial_segments: options.radial_segments,
        height_segments: options.height_segments,
        open_ended: options.open_ended,
    })
}
