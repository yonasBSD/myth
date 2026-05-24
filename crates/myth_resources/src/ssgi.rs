//! SSGI (Screen Space Global Illumination) Configuration
//!
//! This module follows the same pattern as other screen-space effect settings:
//! CPU-side data lives in a versioned [`CpuBuffer`], while user-facing
//! setters mutate strongly typed fields and let the renderer upload only when
//! values actually change.

use glam::{UVec4, Vec4};

use myth_macros::gpu_struct;

use crate::buffer::{BufferGuard, BufferReadGuard, CpuBuffer};

/// Quality preset for screen-space global illumination.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash, Default)]
pub enum SsgiQuality {
    /// Half-resolution checkerboard tracing with short rays.
    Low,
    /// Balanced tracing budget for mid-range GPUs.
    Medium,
    /// Default full-quality tracing budget.
    #[default]
    High,
    /// Extended ray budget for high-end desktop GPUs.
    Ultra,
    /// The settings have been manually overridden.
    Custom,
}

impl SsgiQuality {
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
    pub const fn all() -> &'static [SsgiQuality] {
        &[Self::Low, Self::Medium, Self::High, Self::Ultra]
    }
}

#[gpu_struct(crate_path = "crate")]
pub struct SsgiUniforms {
    /// (full_width, full_height, inv_full_width, inv_full_height)
    pub full_resolution: Vec4,
    /// (half_width, half_height, inv_half_width, inv_half_height)
    pub half_resolution: Vec4,
    /// (intensity, max_distance, thickness, ray_stride)
    pub ray_params: Vec4,
    /// (history_alpha, normal_rejection, depth_rejection, blur_depth_sigma)
    pub reprojection_params: Vec4,
    /// (fallback_env_weight, hiz_mip_bias, spatial_normal_power, luma_phi)
    pub lighting_params: Vec4,
    /// (frame_index, max_steps, checkerboard_enabled, reserved)
    pub frame_params: UVec4,
    /// (atrous_passes, atrous_step_size, thickness_heuristic_enabled, reserved)
    pub denoise_params: UVec4,
}

/// Scene-level SSGI settings.
///
/// The feature is disabled by default and must be explicitly enabled.
#[derive(Debug, Clone)]
pub struct SsgiSettings {
    pub enabled: bool,
    quality: SsgiQuality,

    #[doc(hidden)]
    pub uniforms: CpuBuffer<SsgiUniforms>,
}

impl Default for SsgiSettings {
    fn default() -> Self {
        let uniforms = SsgiUniforms {
            full_resolution: Vec4::new(1.0, 1.0, 1.0, 1.0),
            half_resolution: Vec4::new(1.0, 1.0, 1.0, 1.0),
            ray_params: Vec4::new(1.0, 6.0, 0.2, 0.12),
            reprojection_params: Vec4::new(0.12, 0.85, 0.15, 0.75),
            lighting_params: Vec4::new(1.0, 0.0, 32.0, 0.35),
            frame_params: UVec4::new(0, 16, 0, 0),
            denoise_params: UVec4::new(3, 1, 1, 0),
        };

        Self {
            enabled: false,
            quality: SsgiQuality::High,
            uniforms: CpuBuffer::new(
                uniforms,
                wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
                Some("SSGI Uniforms"),
            ),
        }
    }
}

impl SsgiSettings {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    pub fn set_enabled(&mut self, enabled: bool) {
        self.enabled = enabled;
    }

    #[must_use]
    pub fn quality(&self) -> SsgiQuality {
        self.quality
    }

    pub fn set_quality(&mut self, quality: SsgiQuality) {
        match quality {
            SsgiQuality::Custom => {
                self.quality = SsgiQuality::Custom;
            }
            _ => self.apply_quality_preset(quality),
        }
    }

    pub fn uniforms(&self) -> BufferReadGuard<'_, SsgiUniforms> {
        self.uniforms.read()
    }

    pub fn uniforms_mut(&mut self) -> BufferGuard<'_, SsgiUniforms> {
        self.mark_custom();
        self.uniforms.write()
    }

    pub fn set_intensity(&mut self, intensity: f32) {
        self.mark_custom();
        self.uniforms.write().ray_params.x = intensity.max(0.0);
    }

    #[must_use]
    pub fn intensity(&self) -> f32 {
        self.uniforms.read().ray_params.x
    }

    pub fn set_max_distance(&mut self, max_distance: f32) {
        self.mark_custom();
        self.uniforms.write().ray_params.y = max_distance.max(0.1);
    }

    #[must_use]
    pub fn max_distance(&self) -> f32 {
        self.uniforms.read().ray_params.y
    }

    pub fn set_thickness(&mut self, thickness: f32) {
        self.mark_custom();
        self.uniforms.write().ray_params.z = thickness.max(0.001);
    }

    #[must_use]
    pub fn thickness(&self) -> f32 {
        self.uniforms.read().ray_params.z
    }

    pub fn set_ray_stride(&mut self, stride: f32) {
        self.mark_custom();
        self.uniforms.write().ray_params.w = stride.max(0.001);
    }

    #[must_use]
    pub fn ray_stride(&self) -> f32 {
        self.uniforms.read().ray_params.w
    }

    pub fn set_history_alpha(&mut self, alpha: f32) {
        self.mark_custom();
        self.uniforms.write().reprojection_params.x = alpha.clamp(0.01, 1.0);
    }

    #[must_use]
    pub fn history_alpha(&self) -> f32 {
        self.uniforms.read().reprojection_params.x
    }

    pub fn set_normal_rejection(&mut self, threshold: f32) {
        self.mark_custom();
        self.uniforms.write().reprojection_params.y = threshold.clamp(0.0, 1.0);
    }

    #[must_use]
    pub fn normal_rejection(&self) -> f32 {
        self.uniforms.read().reprojection_params.y
    }

    pub fn set_depth_rejection(&mut self, threshold: f32) {
        self.mark_custom();
        self.uniforms.write().reprojection_params.z = threshold.max(0.0);
    }

    #[must_use]
    pub fn depth_rejection(&self) -> f32 {
        self.uniforms.read().reprojection_params.z
    }

    pub fn set_blur_depth_sigma(&mut self, sigma: f32) {
        self.mark_custom();
        self.uniforms.write().reprojection_params.w = sigma.max(0.001);
    }

    #[must_use]
    pub fn blur_depth_sigma(&self) -> f32 {
        self.uniforms.read().reprojection_params.w
    }

    pub fn set_fallback_env_weight(&mut self, weight: f32) {
        self.mark_custom();
        self.uniforms.write().lighting_params.x = weight.clamp(0.0, 1.0);
    }

    #[must_use]
    pub fn fallback_env_weight(&self) -> f32 {
        self.uniforms.read().lighting_params.x
    }

    pub fn set_hiz_mip_bias(&mut self, bias: f32) {
        self.mark_custom();
        self.uniforms.write().lighting_params.y = bias.max(0.0);
    }

    #[must_use]
    pub fn hiz_mip_bias(&self) -> f32 {
        self.uniforms.read().lighting_params.y
    }

    pub fn set_spatial_normal_power(&mut self, power: f32) {
        self.mark_custom();
        self.uniforms.write().lighting_params.z = power.max(1.0);
    }

    #[must_use]
    pub fn spatial_normal_power(&self) -> f32 {
        self.uniforms.read().lighting_params.z
    }

    pub fn set_luma_phi(&mut self, phi: f32) {
        self.mark_custom();
        self.uniforms.write().lighting_params.w = phi.max(0.001);
    }

    #[must_use]
    pub fn luma_phi(&self) -> f32 {
        self.uniforms.read().lighting_params.w
    }

    pub fn set_max_steps(&mut self, max_steps: u32) {
        self.mark_custom();
        self.uniforms.write().frame_params.y = max_steps.clamp(4, 64);
    }

    #[must_use]
    pub fn max_steps(&self) -> u32 {
        self.uniforms.read().frame_params.y
    }

    pub fn set_checkerboard_enabled(&mut self, enabled: bool) {
        self.mark_custom();
        self.uniforms.write().frame_params.z = u32::from(enabled);
    }

    #[must_use]
    pub fn checkerboard_enabled(&self) -> bool {
        self.uniforms.read().frame_params.z != 0
    }

    pub fn set_atrous_passes(&mut self, passes: u32) {
        self.mark_custom();
        self.uniforms.write().denoise_params.x = passes.clamp(1, 4);
    }

    #[must_use]
    pub fn atrous_passes(&self) -> u32 {
        self.uniforms.read().denoise_params.x
    }

    pub fn set_thickness_heuristic_enabled(&mut self, enabled: bool) {
        self.mark_custom();
        self.uniforms.write().denoise_params.z = u32::from(enabled);
    }

    #[must_use]
    pub fn thickness_heuristic_enabled(&self) -> bool {
        self.uniforms.read().denoise_params.z != 0
    }

    pub fn set_frame_index(&mut self, frame_index: u32) {
        self.uniforms.write().frame_params.x = frame_index;
    }

    #[must_use]
    pub fn frame_index(&self) -> u32 {
        self.uniforms.read().frame_params.x
    }

    pub fn set_history_flags(&mut self, flags: u32) {
        self.uniforms.write().frame_params.w = flags;
    }

    #[must_use]
    pub fn history_flags(&self) -> u32 {
        self.uniforms.read().frame_params.w
    }

    pub fn update_resolution(&mut self, width: u32, height: u32) {
        let half_w = (width / 2).max(1);
        let half_h = (height / 2).max(1);
        let full = Vec4::new(
            width as f32,
            height as f32,
            1.0 / width.max(1) as f32,
            1.0 / height.max(1) as f32,
        );
        let half = Vec4::new(
            half_w as f32,
            half_h as f32,
            1.0 / half_w as f32,
            1.0 / half_h as f32,
        );

        let current_full = self.uniforms.read().full_resolution;
        let current_half = self.uniforms.read().half_resolution;
        if current_full != full || current_half != half {
            let mut guard = self.uniforms.write();
            guard.full_resolution = full;
            guard.half_resolution = half;
        }
    }

    fn mark_custom(&mut self) {
        self.quality = SsgiQuality::Custom;
    }

    fn apply_quality_preset(&mut self, quality: SsgiQuality) {
        let mut guard = self.uniforms.write();
        match quality {
            SsgiQuality::Low => {
                guard.ray_params = Vec4::new(0.9, 4.5, 0.28, 0.22);
                guard.reprojection_params = Vec4::new(0.08, 0.80, 0.18, 1.10);
                guard.lighting_params = Vec4::new(1.0, 0.45, 16.0, 0.45);
                guard.frame_params.y = 8;
                guard.frame_params.z = 1;
                guard.denoise_params = UVec4::new(1, 1, 0, 0);
            }
            SsgiQuality::Medium => {
                guard.ray_params = Vec4::new(1.0, 5.5, 0.24, 0.16);
                guard.reprojection_params = Vec4::new(0.10, 0.84, 0.16, 0.90);
                guard.lighting_params = Vec4::new(1.0, 0.25, 24.0, 0.40);
                guard.frame_params.y = 12;
                guard.frame_params.z = 1;
                guard.denoise_params = UVec4::new(2, 1, 1, 0);
            }
            SsgiQuality::High => {
                guard.ray_params = Vec4::new(1.0, 6.0, 0.20, 0.12);
                guard.reprojection_params = Vec4::new(0.12, 0.85, 0.15, 0.75);
                guard.lighting_params = Vec4::new(1.0, 0.0, 32.0, 0.35);
                guard.frame_params.y = 16;
                guard.frame_params.z = 0;
                guard.denoise_params = UVec4::new(3, 1, 1, 0);
            }
            SsgiQuality::Ultra => {
                guard.ray_params = Vec4::new(1.0, 8.0, 0.16, 0.08);
                guard.reprojection_params = Vec4::new(0.16, 0.90, 0.12, 0.55);
                guard.lighting_params = Vec4::new(1.0, 0.0, 48.0, 0.30);
                guard.frame_params.y = 24;
                guard.frame_params.z = 0;
                guard.denoise_params = UVec4::new(4, 1, 1, 0);
            }
            SsgiQuality::Custom => return,
        }

        self.quality = quality;
    }
}
