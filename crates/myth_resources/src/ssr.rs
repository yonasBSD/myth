//! SSR (Screen Space Reflections) configuration.
//!
//! The scene-level toggle remains in `ScreenSpaceSettings::enable_ssr` so SSR
//! can share the existing screen-space feature routing. This module stores the
//! per-frame GPU tuning parameters and quality presets used by the renderer.

use glam::{UVec4, Vec4};

use myth_macros::gpu_struct;

use crate::buffer::{BufferGuard, BufferReadGuard, CpuBuffer};

/// Quality preset for screen-space reflections.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum SsrQuality {
    Low,
    Medium,
    #[default]
    High,
    Ultra,
    Custom,
}

impl SsrQuality {
    #[must_use]
    pub const fn name(self) -> &'static str {
        match self {
            Self::Low => "Low",
            Self::Medium => "Medium",
            Self::High => "High",
            Self::Ultra => "Ultra",
            Self::Custom => "Custom",
        }
    }

    #[must_use]
    pub const fn all() -> &'static [SsrQuality] {
        &[Self::Low, Self::Medium, Self::High, Self::Ultra]
    }
}

#[gpu_struct(crate_path = "crate")]
pub struct SsrUniforms {
    /// (width, height, inv_width, inv_height)
    pub full_resolution: Vec4,
    /// (intensity, max_distance, thickness, trace_start_bias)
    pub ray_params: Vec4,
    /// (history_alpha, normal_rejection, depth_rejection, roughness_rejection)
    pub reprojection_params: Vec4,
    /// (edge_fade_start, edge_fade_end, backface_fade_start, backface_fade_end)
    pub fade_params: Vec4,
    /// (roughness_cutoff, hiz_mip_bias, spatial_normal_power, luma_phi)
    pub shading_params: Vec4,
    /// (variance_gamma, firefly_luma_limit, camera_near, reserved)
    pub temporal_params: Vec4,
    /// (frame_index, max_steps, spatial_filter_enabled, history_flags)
    pub frame_params: UVec4,
    /// (spatial_radius, reserved, reserved, reserved)
    pub denoise_params: UVec4,
}

/// Scene-level SSR tuning state.
#[derive(Debug, Clone)]
pub struct SsrSettings {
    quality: SsrQuality,

    #[doc(hidden)]
    pub uniforms: CpuBuffer<SsrUniforms>,
}

impl Default for SsrSettings {
    fn default() -> Self {
        let uniforms = SsrUniforms {
            full_resolution: Vec4::new(1.0, 1.0, 1.0, 1.0),
            ray_params: Vec4::new(1.0, 16.0, 0.15, 0.05),
            reprojection_params: Vec4::new(0.10, 0.86, 0.12, 0.14),
            fade_params: Vec4::new(0.76, 0.98, -0.04, 0.22),
            shading_params: Vec4::new(0.70, 0.0, 24.0, 0.30),
            temporal_params: Vec4::new(1.25, 20.0, 0.1, 0.0),
            frame_params: UVec4::new(0, 24, 1, 0),
            denoise_params: UVec4::new(1, 0, 0, 0),
        };

        Self {
            quality: SsrQuality::High,
            uniforms: CpuBuffer::new(
                uniforms,
                wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
                Some("SSR Uniforms"),
            ),
        }
    }
}

impl SsrSettings {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    #[must_use]
    pub fn quality(&self) -> SsrQuality {
        self.quality
    }

    pub fn set_quality(&mut self, quality: SsrQuality) {
        match quality {
            SsrQuality::Custom => self.quality = SsrQuality::Custom,
            _ => self.apply_quality_preset(quality),
        }
    }

    pub fn uniforms(&self) -> BufferReadGuard<'_, SsrUniforms> {
        self.uniforms.read()
    }

    pub fn uniforms_mut(&mut self) -> BufferGuard<'_, SsrUniforms> {
        self.mark_custom();
        self.uniforms.write()
    }

    pub fn set_intensity(&mut self, intensity: f32) {
        self.mark_custom();
        self.uniforms.write().ray_params.x = intensity.max(0.0);
    }

    pub fn set_max_distance(&mut self, max_distance: f32) {
        self.mark_custom();
        self.uniforms.write().ray_params.y = max_distance.max(0.1);
    }

    pub fn set_thickness(&mut self, thickness: f32) {
        self.mark_custom();
        self.uniforms.write().ray_params.z = thickness.max(0.001);
    }

    pub fn set_trace_start_bias(&mut self, bias: f32) {
        self.mark_custom();
        self.uniforms.write().ray_params.w = bias.max(0.001);
    }

    pub fn set_history_alpha(&mut self, alpha: f32) {
        self.mark_custom();
        self.uniforms.write().reprojection_params.x = alpha.clamp(0.01, 1.0);
    }

    pub fn set_roughness_cutoff(&mut self, cutoff: f32) {
        self.mark_custom();
        self.uniforms.write().shading_params.x = cutoff.clamp(0.05, 1.0);
    }

    pub fn set_max_steps(&mut self, max_steps: u32) {
        self.mark_custom();
        self.uniforms.write().frame_params.y = max_steps.max(1);
    }

    pub fn set_spatial_radius(&mut self, radius: u32) {
        self.mark_custom();
        self.uniforms.write().denoise_params.x = radius.clamp(1, 4);
    }

    pub fn set_frame_index(&mut self, frame_index: u32) {
        self.uniforms.write().frame_params.x = frame_index;
    }

    pub fn set_history_flags(&mut self, flags: u32) {
        self.uniforms.write().frame_params.w = flags;
    }

    pub fn set_runtime_camera_near(&mut self, near: f32) {
        self.uniforms.write().temporal_params.z = near.max(0.0001);
    }

    pub fn update_resolution(&mut self, width: u32, height: u32) {
        let full = Vec4::new(
            width as f32,
            height as f32,
            1.0 / width.max(1) as f32,
            1.0 / height.max(1) as f32,
        );

        if self.uniforms.read().full_resolution != full {
            self.uniforms.write().full_resolution = full;
        }
    }

    fn mark_custom(&mut self) {
        self.quality = SsrQuality::Custom;
    }

    fn apply_quality_preset(&mut self, quality: SsrQuality) {
        let mut guard = self.uniforms.write();
        match quality {
            SsrQuality::Low => {
                guard.ray_params = Vec4::new(0.9, 8.0, 0.15, 0.08);
                guard.reprojection_params = Vec4::new(0.14, 0.80, 0.18, 0.18);
                guard.fade_params = Vec4::new(0.70, 0.96, -0.02, 0.24);
                guard.shading_params = Vec4::new(0.40, 0.45, 16.0, 0.42);
                guard.temporal_params = Vec4::new(1.8, 16.0, guard.temporal_params.z, 0.0);
                guard.frame_params = UVec4::new(guard.frame_params.x, 16, 1, 0);
                guard.denoise_params = UVec4::new(1, 0, 0, 0);
            }
            SsrQuality::Medium => {
                guard.ray_params = Vec4::new(1.0, 12.0, 0.10, 0.06);
                guard.reprojection_params = Vec4::new(0.12, 0.83, 0.15, 0.16);
                guard.fade_params = Vec4::new(0.74, 0.97, -0.03, 0.23);
                guard.shading_params = Vec4::new(0.55, 0.2, 20.0, 0.34);
                guard.temporal_params = Vec4::new(1.5, 18.0, guard.temporal_params.z, 0.0);
                guard.frame_params = UVec4::new(guard.frame_params.x, 24, 1, 0);
                guard.denoise_params = UVec4::new(1, 0, 0, 0);
            }
            SsrQuality::High => {
                guard.ray_params = Vec4::new(1.0, 16.0, 0.05, 0.05);
                guard.reprojection_params = Vec4::new(0.10, 0.86, 0.12, 0.14);
                guard.fade_params = Vec4::new(0.76, 0.98, -0.04, 0.22);
                guard.shading_params = Vec4::new(0.70, 0.0, 24.0, 0.30);
                guard.temporal_params = Vec4::new(1.25, 20.0, guard.temporal_params.z, 0.0);
                guard.frame_params = UVec4::new(guard.frame_params.x, 48, 1, 0);
                guard.denoise_params = UVec4::new(1, 0, 0, 0);
            }
            SsrQuality::Ultra => {
                guard.ray_params = Vec4::new(1.0, 24.0, 0.02, 0.03);
                guard.reprojection_params = Vec4::new(0.08, 0.90, 0.10, 0.12);
                guard.fade_params = Vec4::new(0.78, 0.99, -0.05, 0.20);
                guard.shading_params = Vec4::new(0.75, 0.0, 28.0, 0.24);
                guard.temporal_params = Vec4::new(1.1, 24.0, guard.temporal_params.z, 0.0);
                guard.frame_params = UVec4::new(guard.frame_params.x, 80, 1, 0);
                guard.denoise_params = UVec4::new(2, 0, 0, 0);
            }
            SsrQuality::Custom => unreachable!("custom preset handled by set_quality"),
        }

        self.quality = quality;
    }
}