//! Clustered lighting feature.
//!
//! This feature owns the persistent CPU-updated buffers required to drive the
//! clustered-lighting compute passes and injects the transient RDG buffer flow
//! that forwards clustered light lists into the forward scene passes.

use crate::core::gpu::Tracked;
use crate::graph::composer::GraphBuilderContext;
use crate::graph::core::{
    BufferDesc, BufferNodeId, ExecuteContext, ExtractContext, PassNode, PrepareContext,
};
use crate::pipeline::{
    ComputePipelineId, ComputePipelineKey, ShaderCompilationOptions, ShaderSource,
};
use myth_resources::uniforms::{
    ClusterAabb, ClusterRecord, ClusteredLightingParams, clustered_lighting_structs_wgsl,
};
use myth_scene::light::LightKind;

/// Default cluster depth slices for forward clustered lighting.
pub const DEFAULT_CLUSTER_Z_SLICES: u32 = 24;
/// Approximate screen-space tile size in pixels.
pub const DEFAULT_CLUSTER_TILE_SIZE: u32 = 120;
/// Hard cap per cluster for the first implementation.
pub const DEFAULT_MAX_LIGHTS_PER_CLUSTER: u32 = 128;
/// Fallback finite far depth when using an infinite reverse-Z camera.
pub const DEFAULT_CLUSTER_FAR_DEPTH_FALLBACK: f32 = 64.0;
/// Bit flag stored in `ClusteredLightingParams::budget.z`.
pub const CLUSTERED_LIGHTING_FLAG_ENABLED: u32 = 1;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ClusteredLightingConfig {
    pub tile_size_x: u32,
    pub tile_size_y: u32,
    pub slices_z: u32,
    pub max_lights_per_cluster: u32,
}

impl Default for ClusteredLightingConfig {
    fn default() -> Self {
        Self {
            tile_size_x: DEFAULT_CLUSTER_TILE_SIZE,
            tile_size_y: DEFAULT_CLUSTER_TILE_SIZE,
            slices_z: DEFAULT_CLUSTER_Z_SLICES,
            max_lights_per_cluster: DEFAULT_MAX_LIGHTS_PER_CLUSTER,
        }
    }
}

pub struct ClusteredLightingFeature {
    pub config: ClusteredLightingConfig,
    params_buffer: Option<Tracked<wgpu::Buffer>>,
    build_layout: Option<Tracked<wgpu::BindGroupLayout>>,
    cull_layout: Option<Tracked<wgpu::BindGroupLayout>>,
    build_pipeline: Option<ComputePipelineId>,
    cull_pipeline: Option<ComputePipelineId>,
    frame_params: ClusteredLightingParams,
}

pub struct ClusteredLightingOutputs {
    pub params_buffer: BufferNodeId,
    pub cluster_records: Option<BufferNodeId>,
    pub light_indices: Option<BufferNodeId>,
}

impl Default for ClusteredLightingFeature {
    fn default() -> Self {
        Self::new()
    }
}

impl ClusteredLightingFeature {
    #[must_use]
    pub fn new() -> Self {
        Self {
            config: ClusteredLightingConfig::default(),
            params_buffer: None,
            build_layout: None,
            cull_layout: None,
            build_pipeline: None,
            cull_pipeline: None,
            frame_params: ClusteredLightingParams::default(),
        }
    }

    #[inline]
    #[must_use]
    pub fn params_desc(&self) -> BufferDesc {
        BufferDesc::new(
            std::mem::size_of::<ClusteredLightingParams>() as u64,
            wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
        )
    }

    #[inline]
    #[must_use]
    pub fn cluster_aabb_desc(&self) -> BufferDesc {
        BufferDesc::new(
            u64::from(self.frame_params.grid_dimensions.y)
                * std::mem::size_of::<ClusterAabb>() as u64,
            wgpu::BufferUsages::STORAGE,
        )
    }

    #[inline]
    #[must_use]
    pub fn cluster_record_desc(&self) -> BufferDesc {
        BufferDesc::new(
            u64::from(self.frame_params.grid_dimensions.y)
                * std::mem::size_of::<ClusterRecord>() as u64,
            wgpu::BufferUsages::STORAGE,
        )
    }

    #[inline]
    #[must_use]
    pub fn light_index_desc(&self) -> BufferDesc {
        BufferDesc::new(
            u64::from(self.frame_params.budget.y) * std::mem::size_of::<u32>() as u64,
            wgpu::BufferUsages::STORAGE,
        )
    }

    #[must_use]
    pub fn params_buffer(&self) -> Option<&Tracked<wgpu::Buffer>> {
        self.params_buffer.as_ref()
    }

    #[must_use]
    pub fn frame_params(&self) -> ClusteredLightingParams {
        self.frame_params
    }

    fn ensure_layouts(&mut self, device: &wgpu::Device) {
        if self.build_layout.is_some() {
            return;
        }

        self.build_layout = Some(Tracked::new(device.create_bind_group_layout(
            &wgpu::BindGroupLayoutDescriptor {
                label: Some("Cluster Build Layout"),
                entries: &[uniform_entry(0), storage_entry(1, false)],
            },
        )));

        self.cull_layout = Some(Tracked::new(device.create_bind_group_layout(
            &wgpu::BindGroupLayoutDescriptor {
                label: Some("Cluster Cull Layout"),
                entries: &[
                    uniform_entry(0),
                    storage_entry(1, true),
                    storage_entry(2, false),
                    storage_entry(3, false),
                ],
            },
        )));
    }

    fn ensure_pipelines(&mut self, ctx: &mut ExtractContext) {
        if self.build_pipeline.is_some() && self.cull_pipeline.is_some() {
            return;
        }

        self.ensure_layouts(ctx.device);

        let global_state_key = (ctx.render_state.id, ctx.extracted_scene.scene_id);
        let gpu_world = ctx
            .resource_manager
            .get_global_state(global_state_key.0, global_state_key.1)
            .expect("Clustered lighting requires a prepared global bind group");

        let compilation_options = wgpu::PipelineCompilationOptions::default();
        let build_layout = self
            .build_layout
            .as_ref()
            .expect("cluster build layout missing");
        let cull_layout = self
            .cull_layout
            .as_ref()
            .expect("cluster cull layout missing");

        if self.build_pipeline.is_none() {
            let mut options = ShaderCompilationOptions::default();
            options.inject_code("binding_code", &gpu_world.binding_wgsl);
            options.inject_code(
                "clustered_lighting_structs",
                &clustered_lighting_structs_wgsl(),
            );
            let (module, shader_hash) = ctx.shader_manager.get_or_compile(
                ctx.device,
                ShaderSource::File("entry/utility/clustered/cluster_build"),
                &options,
            );

            let layout = ctx
                .device
                .create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                    label: Some("Cluster Build Pipeline Layout"),
                    bind_group_layouts: &[Some(&gpu_world.layout), Some(build_layout)],
                    immediate_size: 0,
                });

            self.build_pipeline = Some(
                ctx.pipeline_cache.get_or_create_compute(
                    ctx.device,
                    module,
                    &layout,
                    &ComputePipelineKey::new(shader_hash)
                        .with_compilation_options(&compilation_options),
                    &compilation_options,
                    "Cluster Build Pipeline",
                ),
            );
        }

        if self.cull_pipeline.is_none() {
            let mut options = ShaderCompilationOptions::default();
            options.inject_code("binding_code", &gpu_world.binding_wgsl);
            options.inject_code(
                "clustered_lighting_structs",
                &clustered_lighting_structs_wgsl(),
            );
            let (module, shader_hash) = ctx.shader_manager.get_or_compile(
                ctx.device,
                ShaderSource::File("entry/utility/clustered/cluster_cull"),
                &options,
            );

            let layout = ctx
                .device
                .create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
                    label: Some("Cluster Cull Pipeline Layout"),
                    bind_group_layouts: &[Some(&gpu_world.layout), Some(cull_layout)],
                    immediate_size: 0,
                });

            self.cull_pipeline = Some(
                ctx.pipeline_cache.get_or_create_compute(
                    ctx.device,
                    module,
                    &layout,
                    &ComputePipelineKey::new(shader_hash)
                        .with_compilation_options(&compilation_options),
                    &compilation_options,
                    "Cluster Cull Pipeline",
                ),
            );
        }
    }

    pub fn extract_and_prepare(
        &mut self,
        ctx: &mut ExtractContext,
        enabled: bool,
        active_light_count: u32,
    ) {
        let render_uniforms = ctx.render_state.uniforms().read();
        let width = render_uniforms.viewport.x.max(1.0) as u32;
        let height = render_uniforms.viewport.y.max(1.0) as u32;
        let near = render_uniforms.camera_near.max(0.001);
        let camera_far = render_uniforms.camera_far;
        drop(render_uniforms);

        let far = resolve_cluster_far_depth(
            near,
            camera_far,
            estimate_cluster_scene_max_depth(ctx),
        );

        let cluster_x = width.div_ceil(self.config.tile_size_x.max(1));
        let cluster_y = height.div_ceil(self.config.tile_size_y.max(1));
        let cluster_z = self.config.slices_z.max(1);
        let total_clusters = cluster_x
            .saturating_mul(cluster_y)
            .saturating_mul(cluster_z)
            .max(1);
        let max_storage_bytes = ctx.device.limits().max_storage_buffer_binding_size as u64;
        let max_indices_by_limit =
            (max_storage_bytes / std::mem::size_of::<u32>() as u64).max(u64::from(total_clusters));
        let requested_light_indices =
            u64::from(total_clusters) * u64::from(self.config.max_lights_per_cluster.max(1));
        let effective_light_indices = requested_light_indices.min(max_indices_by_limit);
        let effective_max_lights =
            (effective_light_indices / u64::from(total_clusters)).max(1) as u32;

        if effective_max_lights < self.config.max_lights_per_cluster {
            log::warn!(
                "Clustered lighting light-index buffer clamped from {} to {} lights per cluster by maxStorageBufferBindingSize",
                self.config.max_lights_per_cluster,
                effective_max_lights,
            );
        }

        let log_ratio = (far / near).ln().max(0.0001);
        let slice_scale = cluster_z as f32 / log_ratio;
        let slice_bias = -(near.ln() * slice_scale);

        self.frame_params = ClusteredLightingParams {
            screen_dimensions: glam::UVec4::new(width, height, cluster_x, cluster_y),
            grid_dimensions: glam::UVec4::new(
                cluster_z,
                total_clusters,
                self.config.tile_size_x.max(1),
                self.config.tile_size_y.max(1),
            ),
            budget: glam::UVec4::new(
                effective_max_lights,
                effective_light_indices.max(1) as u32,
                if enabled {
                    CLUSTERED_LIGHTING_FLAG_ENABLED
                } else {
                    0
                },
                active_light_count,
            ),
            depth_params: glam::Vec4::new(near, far, slice_scale, slice_bias),
        };

        self.ensure_pipelines(ctx);

        let params_desc = self.params_desc();
        ensure_tracked_buffer(
            &mut self.params_buffer,
            ctx.device,
            params_desc,
            "Clustered Lighting Params",
        );

        ctx.queue.write_buffer(
            self.params_buffer
                .as_ref()
                .expect("clustered params buffer must exist"),
            0,
            bytemuck::bytes_of(&self.frame_params),
        );
    }

    pub fn add_to_graph<'a>(
        &'a self,
        ctx: &mut GraphBuilderContext<'a, '_>,
        enabled: bool,
    ) -> ClusteredLightingOutputs {
        let params_buffer = self
            .params_buffer
            .as_ref()
            .expect("Clustered lighting params buffer must exist before graph build");
        let imported_params = ctx.graph.add_pass("Cluster_Params_Import", |builder| {
            let params_buffer = builder.read_external_buffer(
                "Clustered_Params",
                BufferDesc::new(
                    std::mem::size_of::<ClusteredLightingParams>() as u64,
                    wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
                ),
                params_buffer,
            );
            (ClusterParamsImportPassNode, params_buffer)
        });

        if !enabled {
            return ClusteredLightingOutputs {
                params_buffer: imported_params,
                cluster_records: None,
                light_indices: None,
            };
        }

        let build_layout = self
            .build_layout
            .as_ref()
            .expect("Clustered lighting build layout must exist");
        let cull_layout = self
            .cull_layout
            .as_ref()
            .expect("Clustered lighting cull layout must exist");
        let build_pipeline = ctx.pipeline_cache.get_compute_pipeline(
            self.build_pipeline
                .expect("Clustered build pipeline missing"),
        );
        let cull_pipeline = ctx
            .pipeline_cache
            .get_compute_pipeline(self.cull_pipeline.expect("Clustered cull pipeline missing"));

        let build_outputs = ctx.graph.add_pass("Cluster_Build_Pass", |builder| {
            let params_buffer = builder.read_buffer(imported_params);
            let cluster_aabbs = builder.create_buffer("Cluster_Aabbs", self.cluster_aabb_desc());

            let node = ClusterBuildPassNode {
                params_buffer,
                cluster_aabbs,
                build_layout,
                build_pipeline,
                bind_group: None,
                total_clusters: self.frame_params.grid_dimensions.y,
            };
            (
                node,
                ClusterBuildOutputs {
                    params_buffer,
                    cluster_aabbs,
                },
            )
        });

        ctx.graph.add_pass("Cluster_Cull_Pass", |builder| {
            let params_buffer = builder.read_buffer(build_outputs.params_buffer);
            let cluster_aabbs = builder.read_buffer(build_outputs.cluster_aabbs);
            let cluster_records =
                builder.create_buffer("Cluster_Records", self.cluster_record_desc());
            let light_indices =
                builder.create_buffer("Cluster_Light_Indices", self.light_index_desc());

            let node = ClusterCullPassNode {
                params_buffer,
                cluster_aabbs,
                cluster_records,
                light_indices,
                cull_layout,
                cull_pipeline,
                bind_group: None,
                total_clusters: self.frame_params.grid_dimensions.y,
            };
            (
                node,
                ClusteredLightingOutputs {
                    params_buffer,
                    cluster_records: Some(cluster_records),
                    light_indices: Some(light_indices),
                },
            )
        })
    }
}

fn estimate_cluster_scene_max_depth(ctx: &ExtractContext) -> Option<f32> {
    let view_matrix = ctx.render_camera.view_matrix;
    let mut max_depth = 0.0_f32;

    for item in &ctx.extracted_scene.render_items {
        let aabb = item.world_aabb;
        if !aabb.is_finite() {
            continue;
        }

        let view_center = view_matrix * aabb.center().extend(1.0);
        let view_radius = aabb.size().length() * 0.5;
        let far_depth = -view_center.z + view_radius;
        if far_depth.is_finite() {
            max_depth = max_depth.max(far_depth);
        }
    }

    for light in &ctx.extracted_scene.lights {
        let range = match &light.kind {
            LightKind::Point(point) => point.range,
            LightKind::Spot(spot) => spot.range,
            LightKind::Directional(_) => 0.0,
        };

        if range <= 0.0 {
            continue;
        }

        let view_center = view_matrix * light.position.extend(1.0);
        let far_depth = -view_center.z + range;
        if far_depth.is_finite() {
            max_depth = max_depth.max(far_depth);
        }
    }

    (max_depth > 0.0).then_some(max_depth)
}

fn resolve_cluster_far_depth(
    near: f32,
    camera_far: f32,
    estimated_scene_depth: Option<f32>,
) -> f32 {
    if camera_far.is_finite() {
        return camera_far.max(near + 0.001);
    }

    let fallback_depth = estimated_scene_depth.unwrap_or(near + DEFAULT_CLUSTER_FAR_DEPTH_FALLBACK);
    (fallback_depth * 1.1).max(near + DEFAULT_CLUSTER_FAR_DEPTH_FALLBACK)
}

#[derive(Clone, Copy)]
struct ClusterBuildOutputs {
    params_buffer: BufferNodeId,
    cluster_aabbs: BufferNodeId,
}

struct ClusterParamsImportPassNode;

impl PassNode<'_> for ClusterParamsImportPassNode {
    fn prepare(&mut self, _ctx: &mut PrepareContext<'_>) {}

    fn execute(&self, _ctx: &ExecuteContext, _encoder: &mut wgpu::CommandEncoder) {}
}

struct ClusterBuildPassNode<'a> {
    params_buffer: BufferNodeId,
    cluster_aabbs: BufferNodeId,
    build_layout: &'a Tracked<wgpu::BindGroupLayout>,
    build_pipeline: &'a wgpu::ComputePipeline,
    bind_group: Option<&'a wgpu::BindGroup>,
    total_clusters: u32,
}

impl<'a> PassNode<'a> for ClusterBuildPassNode<'a> {
    fn prepare(&mut self, ctx: &mut PrepareContext<'a>) {
        self.bind_group = Some(
            ctx.build_bind_group(self.build_layout, Some("Cluster Build BG"))
                .bind_buffer(0, self.params_buffer)
                .bind_buffer(1, self.cluster_aabbs)
                .build(),
        );
    }

    fn execute(&self, ctx: &ExecuteContext, encoder: &mut wgpu::CommandEncoder) {
        let mut pass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
            label: Some("Cluster Build Pass"),
            timestamp_writes: None,
        });
        pass.set_pipeline(self.build_pipeline);
        pass.set_bind_group(0, ctx.baked_lists.global_bind_group, &[]);
        pass.set_bind_group(1, self.bind_group.expect("Cluster build BG missing"), &[]);
        pass.dispatch_workgroups(self.total_clusters.div_ceil(64), 1, 1);
    }
}

struct ClusterCullPassNode<'a> {
    params_buffer: BufferNodeId,
    cluster_aabbs: BufferNodeId,
    cluster_records: BufferNodeId,
    light_indices: BufferNodeId,
    cull_layout: &'a Tracked<wgpu::BindGroupLayout>,
    cull_pipeline: &'a wgpu::ComputePipeline,
    bind_group: Option<&'a wgpu::BindGroup>,
    total_clusters: u32,
}

impl<'a> PassNode<'a> for ClusterCullPassNode<'a> {
    fn prepare(&mut self, ctx: &mut PrepareContext<'a>) {
        self.bind_group = Some(
            ctx.build_bind_group(self.cull_layout, Some("Cluster Cull BG"))
                .bind_buffer(0, self.params_buffer)
                .bind_buffer(1, self.cluster_aabbs)
                .bind_buffer(2, self.cluster_records)
                .bind_buffer(3, self.light_indices)
                .build(),
        );
    }

    fn execute(&self, ctx: &ExecuteContext, encoder: &mut wgpu::CommandEncoder) {
        let mut pass = encoder.begin_compute_pass(&wgpu::ComputePassDescriptor {
            label: Some("Cluster Cull Pass"),
            timestamp_writes: None,
        });
        pass.set_pipeline(self.cull_pipeline);
        pass.set_bind_group(0, ctx.baked_lists.global_bind_group, &[]);
        pass.set_bind_group(1, self.bind_group.expect("Cluster cull BG missing"), &[]);
        pass.dispatch_workgroups(self.total_clusters.div_ceil(64), 1, 1);
    }
}

fn ensure_tracked_buffer(
    slot: &mut Option<Tracked<wgpu::Buffer>>,
    device: &wgpu::Device,
    desc: BufferDesc,
    label: &'static str,
) {
    let needs_recreate = slot
        .as_ref()
        .is_none_or(|buffer| buffer.size() != desc.logical_size);

    if needs_recreate {
        *slot = Some(Tracked::new(device.create_buffer(
            &wgpu::BufferDescriptor {
                label: Some(label),
                size: desc.logical_size.max(1),
                usage: desc.usage,
                mapped_at_creation: false,
            },
        )));
    }
}

fn uniform_entry(binding: u32) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::COMPUTE,
        ty: wgpu::BindingType::Buffer {
            ty: wgpu::BufferBindingType::Uniform,
            has_dynamic_offset: false,
            min_binding_size: None,
        },
        count: None,
    }
}

fn storage_entry(binding: u32, read_only: bool) -> wgpu::BindGroupLayoutEntry {
    wgpu::BindGroupLayoutEntry {
        binding,
        visibility: wgpu::ShaderStages::COMPUTE,
        ty: wgpu::BindingType::Buffer {
            ty: wgpu::BufferBindingType::Storage { read_only },
            has_dynamic_offset: false,
            min_binding_size: None,
        },
        count: None,
    }
}

#[cfg(test)]
mod tests {
    use super::{DEFAULT_CLUSTER_FAR_DEPTH_FALLBACK, resolve_cluster_far_depth};

    #[test]
    fn infinite_camera_far_resolves_to_finite_cluster_depth() {
        let far = resolve_cluster_far_depth(0.1, f32::INFINITY, Some(48.0));
        assert!(far.is_finite());
        assert!(far > 48.0);
    }

    #[test]
    fn infinite_camera_far_uses_fallback_when_scene_depth_missing() {
        let near = 0.25;
        let far = resolve_cluster_far_depth(near, f32::INFINITY, None);
        assert!(far.is_finite());
        assert!(far >= near + DEFAULT_CLUSTER_FAR_DEPTH_FALLBACK);
    }
}
