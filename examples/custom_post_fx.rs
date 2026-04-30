//! [gallery]
//! name = "Custom Post-FX Pass"
//! category = "Showcase"
//! description = "A fully custom RenderGraph post-process node adding chromatic split, edge glow, and scanline treatment to an emissive scene."
//! instructions = "Space: toggle custom post pass"
//! order = 181
//!

use std::borrow::Cow;

use myth::prelude::*;
use myth::renderer::HDR_TEXTURE_FORMAT;
use myth::renderer::core::gpu::{CommonSampler, Tracked};
use myth::renderer::graph::core::{
    ExecuteContext, GraphBlackboard, HookStage, PassNode, PrepareContext, RenderTargetOps,
    TextureDesc, TextureNodeId,
};
use myth::resources::Key;
use myth_dev_utils::FpsCounter;

const CUSTOM_POST_SHADER: &str = r#"
struct VsOut {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@group(0) @binding(0) var t_input: texture_2d<f32>;
@group(0) @binding(1) var s_input: sampler;

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32) -> VsOut {
    var out: VsOut;
    let pos = array<vec2<f32>, 3>(
        vec2<f32>(-1.0, -3.0),
        vec2<f32>(-1.0,  1.0),
        vec2<f32>( 3.0,  1.0),
    );
    let uv = array<vec2<f32>, 3>(
        vec2<f32>(0.0, 2.0),
        vec2<f32>(0.0, 0.0),
        vec2<f32>(2.0, 0.0),
    );
    out.position = vec4<f32>(pos[vertex_index], 0.0, 1.0);
    out.uv = uv[vertex_index];
    return out;
}

fn luminance(color: vec3<f32>) -> f32 {
    return dot(color, vec3<f32>(0.2126, 0.7152, 0.0722));
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let centered = in.uv * 2.0 - vec2<f32>(1.0, 1.0);
    let radius = length(centered);
    let dir = normalize(centered + vec2<f32>(1e-4, 0.0));
    let aberr = 0.0015 + radius * 0.0075;

    let color_center = textureSample(t_input, s_input, in.uv).rgb;
    let color_right = textureSample(t_input, s_input, in.uv + dir * aberr).rgb;
    let color_left = textureSample(t_input, s_input, in.uv - dir * aberr).rgb;

    var color = vec3<f32>(color_right.r, color_center.g, color_left.b);

    let lum = luminance(color_center);
    let edge_h = abs(lum - luminance(textureSample(t_input, s_input, in.uv + vec2<f32>(0.003, 0.0)).rgb));
    let edge_v = abs(lum - luminance(textureSample(t_input, s_input, in.uv + vec2<f32>(0.0, 0.003)).rgb));
    let edge = clamp((edge_h + edge_v) * 2.8, 0.0, 1.0);

    let scanline = 0.92 + 0.08 * sin(in.uv.y * 900.0);
    let vignette = 1.0 - smoothstep(0.38, 1.15, radius);
    let glow = color_center * vec3<f32>(0.18, 0.24, 0.46) * edge * 2.5;

    color = color * scanline * (0.70 + vignette * 0.55) + glow;
    return vec4<f32>(color, 1.0);
}
"#;

struct ChromaticPostNode<'a> {
    input_tex: TextureNodeId,
    output_tex: TextureNodeId,
    pipeline: &'a wgpu::RenderPipeline,
    layout: &'a Tracked<wgpu::BindGroupLayout>,
    transient_bg: Option<&'a wgpu::BindGroup>,
}

impl<'a> PassNode<'a> for ChromaticPostNode<'a> {
    fn prepare(&mut self, ctx: &mut PrepareContext<'a>) {
        self.transient_bg = Some(myth_render::myth_bind_group!(
            ctx,
            self.layout,
            Some("CustomPostFX BindGroup"),
            [0 => self.input_tex, 1 => CommonSampler::LinearClamp]
        ));
    }

    fn execute(&self, ctx: &ExecuteContext, encoder: &mut wgpu::CommandEncoder) {
        let bind_group = self.transient_bg.expect("custom post bg not prepared");
        let color_attachment =
            ctx.get_color_attachment(self.output_tex, RenderTargetOps::DontCare, None);

        let mut pass = encoder.begin_render_pass(&wgpu::RenderPassDescriptor {
            label: Some("Custom Post FX Pass"),
            color_attachments: &[color_attachment],
            depth_stencil_attachment: None,
            timestamp_writes: None,
            occlusion_query_set: None,
            multiview_mask: None,
        });

        pass.set_pipeline(self.pipeline);
        pass.set_bind_group(0, bind_group, &[]);
        pass.draw(0..3, 0..1);
    }
}

struct PostFxOrb {
    handle: NodeHandle,
    phase: f32,
    radius: f32,
}

struct CustomPostFxDemo {
    controls: OrbitControls,
    fps_counter: FpsCounter,
    orbs: Vec<PostFxOrb>,
    ring_light: NodeHandle,
    post_layout: Tracked<wgpu::BindGroupLayout>,
    post_pipeline: wgpu::RenderPipeline,
    effect_enabled: bool,
    time: f32,
}

impl AppHandler for CustomPostFxDemo {
    fn init(engine: &mut Engine, _window: &dyn Window) -> Self {
        let wgpu_ctx = engine
            .renderer
            .wgpu_ctx()
            .expect("renderer should be initialized before example setup");
        let device = &wgpu_ctx.device;

        let post_layout = Tracked::new(device.create_bind_group_layout(
            &wgpu::BindGroupLayoutDescriptor {
                label: Some("CustomPostFX Layout"),
                entries: &[
                    wgpu::BindGroupLayoutEntry {
                        binding: 0,
                        visibility: wgpu::ShaderStages::FRAGMENT,
                        ty: wgpu::BindingType::Texture {
                            sample_type: wgpu::TextureSampleType::Float { filterable: true },
                            view_dimension: wgpu::TextureViewDimension::D2,
                            multisampled: false,
                        },
                        count: None,
                    },
                    wgpu::BindGroupLayoutEntry {
                        binding: 1,
                        visibility: wgpu::ShaderStages::FRAGMENT,
                        ty: wgpu::BindingType::Sampler(wgpu::SamplerBindingType::Filtering),
                        count: None,
                    },
                ],
            },
        ));

        let shader = device.create_shader_module(wgpu::ShaderModuleDescriptor {
            label: Some("Custom Post FX Shader"),
            source: wgpu::ShaderSource::Wgsl(Cow::Borrowed(CUSTOM_POST_SHADER)),
        });
        let pipeline_layout = device.create_pipeline_layout(&wgpu::PipelineLayoutDescriptor {
            label: Some("Custom Post FX Pipeline Layout"),
            bind_group_layouts: &[Some(&*post_layout)],
            immediate_size: 0,
        });
        let post_pipeline = device.create_render_pipeline(&wgpu::RenderPipelineDescriptor {
            label: Some("Custom Post FX Pipeline"),
            layout: Some(&pipeline_layout),
            vertex: wgpu::VertexState {
                module: &shader,
                entry_point: Some("vs_main"),
                buffers: &[],
                compilation_options: wgpu::PipelineCompilationOptions::default(),
            },
            primitive: wgpu::PrimitiveState::default(),
            depth_stencil: None,
            multisample: wgpu::MultisampleState::default(),
            fragment: Some(wgpu::FragmentState {
                module: &shader,
                entry_point: Some("fs_main"),
                targets: &[Some(wgpu::ColorTargetState {
                    format: HDR_TEXTURE_FORMAT,
                    blend: Some(wgpu::BlendState::REPLACE),
                    write_mask: wgpu::ColorWrites::ALL,
                })],
                compilation_options: wgpu::PipelineCompilationOptions::default(),
            }),
            multiview_mask: None,
            cache: None,
        });

        let sphere_geo = engine.assets.geometries.add(Geometry::new_sphere(1.0));
        let box_geo = engine
            .assets
            .geometries
            .add(Geometry::new_box(1.0, 1.0, 1.0));
        let floor_material = engine
            .assets
            .materials
            .add(PhysicalMaterial::new(Vec4::new(0.05, 0.06, 0.08, 1.0)).with_roughness(0.95));
        let palette = [
            engine.assets.materials.add(
                PhysicalMaterial::new(Vec4::new(0.06, 0.10, 0.16, 1.0))
                    .with_emissive(Vec3::new(0.35, 0.86, 1.0), 4.2)
                    .with_roughness(0.14),
            ),
            engine.assets.materials.add(
                PhysicalMaterial::new(Vec4::new(0.14, 0.06, 0.18, 1.0))
                    .with_emissive(Vec3::new(1.0, 0.42, 0.86), 4.0)
                    .with_roughness(0.16),
            ),
            engine.assets.materials.add(
                PhysicalMaterial::new(Vec4::new(0.16, 0.10, 0.06, 1.0))
                    .with_emissive(Vec3::new(1.0, 0.80, 0.32), 4.0)
                    .with_roughness(0.16),
            ),
        ];

        let scene = engine.scene_manager.create_active();
        scene.environment.set_ambient_light(Vec3::splat(0.01));
        scene.bloom.set_enabled(true);
        scene.bloom.set_strength(0.10);
        scene.bloom.set_radius(0.006);

        let floor = scene.add_mesh(Mesh::new(box_geo, floor_material));
        scene
            .node(&floor)
            .set_position(0.0, -0.12, 0.0)
            .set_scale_xyz(20.0, 0.24, 20.0)
            .set_shadows(false, true);

        let mut orbs = Vec::new();
        for index in 0..48 {
            let handle = scene.add_mesh(Mesh::new(sphere_geo, palette[index % palette.len()]));
            scene
                .node(&handle)
                .set_cast_shadows(false)
                .set_receive_shadows(false);
            orbs.push(PostFxOrb {
                handle,
                phase: index as f32 * 0.37,
                radius: 2.6 + (index % 12) as f32 * 0.28,
            });
        }

        let mut key = Light::new_directional(Vec3::new(0.94, 0.95, 1.0), 1.0);
        key.cast_shadows = true;
        if let Some(shadow) = key.shadow.as_mut() {
            shadow.map_size = 2048;
            shadow.normal_bias = 0.0;
        }
        let key = scene.add_light(key);
        scene
            .node(&key)
            .set_position(8.0, 10.0, 8.0)
            .look_at(Vec3::new(0.0, 1.4, 0.0));

        let ring_light = scene.add_light(Light::new_point(Vec3::new(0.35, 0.9, 1.0), 1.8, 24.0));
        scene.node(&ring_light).set_position(0.0, 4.0, 5.0);

        let cam = scene.add_camera(Camera::new_perspective(45.0, 16.0 / 9.0, 0.1));
        scene
            .node(&cam)
            .set_position(0.0, 3.0, 12.5)
            .look_at(Vec3::new(0.0, 1.4, 0.0));
        scene.active_camera = Some(cam);

        Self {
            controls: OrbitControls::new(Vec3::new(0.0, 3.0, 12.5), Vec3::new(0.0, 1.4, 0.0)),
            fps_counter: FpsCounter::new(),
            orbs,
            ring_light,
            post_layout,
            post_pipeline,
            effect_enabled: true,
            time: 0.0,
        }
    }

    fn update(&mut self, engine: &mut Engine, window: &dyn Window, frame: &FrameState) {
        if engine.input.get_key_down(Key::Space) {
            self.effect_enabled = !self.effect_enabled;
        }

        self.time += frame.dt;
        let Some(scene) = engine.scene_manager.active_scene_mut() else {
            return;
        };

        for (index, orb) in self.orbs.iter().enumerate() {
            let spiral = self.time * (0.55 + index as f32 * 0.002) + orb.phase;
            let rise = ((self.time * 1.1) + orb.phase * 0.8).sin() * 1.8;
            let y = 1.6 + rise + ((index % 6) as f32 - 2.5) * 0.22;
            let x = spiral.cos() * orb.radius;
            let z = spiral.sin() * orb.radius;
            let pulse = 0.18 + 0.12 * (self.time * 1.6 + orb.phase).sin().abs();

            scene
                .node(&orb.handle)
                .set_position(x, y, z)
                .set_scale(pulse);
        }

        if let Some(node) = scene.get_node_mut(self.ring_light) {
            node.transform.position = Vec3::new(
                self.time.cos() * 5.2,
                3.4 + (self.time * 1.4).sin() * 0.9,
                self.time.sin() * 5.2,
            );
        }

        if let Some((transform, camera)) = scene.query_main_camera_bundle() {
            self.controls
                .update(transform, &engine.input, camera.fov(), frame.dt);
        }

        if let Some(fps) = self.fps_counter.update() {
            let mode = if self.effect_enabled {
                "Custom Post FX"
            } else {
                "Raw Scene"
            };
            window.set_title(&format!("Custom Post-FX Pass | {} | FPS: {:.1}", mode, fps));
        }
    }

    fn render(&mut self, engine: &mut Engine, _window: &dyn Window) {
        let (width, height) = engine.renderer.size();
        let post_output_desc = TextureDesc::new_2d(
            width.max(1),
            height.max(1),
            HDR_TEXTURE_FORMAT,
            wgpu::TextureUsages::RENDER_ATTACHMENT
                | wgpu::TextureUsages::TEXTURE_BINDING
                | wgpu::TextureUsages::COPY_SRC,
        );

        let Some(composer) = engine.compose_frame() else {
            return;
        };

        let enabled = self.effect_enabled;
        let pipeline = &self.post_pipeline;
        let layout = &self.post_layout;
        let post_output_desc = post_output_desc;

        composer
            .add_custom_pass(HookStage::BeforePostProcess, move |rdg, blackboard| {
                if !enabled {
                    return blackboard;
                }

                let Some(scene_color) = blackboard.scene_color else {
                    return blackboard;
                };

                let new_color = rdg.add_pass("Custom_Post_FX", |builder| {
                    builder.read_texture(scene_color);
                    let out = builder.create_texture("Scene_Color_CustomPost", post_output_desc);
                    (
                        ChromaticPostNode {
                            input_tex: scene_color,
                            output_tex: out,
                            pipeline,
                            layout,
                            transient_bg: None,
                        },
                        out,
                    )
                });

                GraphBlackboard {
                    scene_color: Some(new_color),
                    ..blackboard
                }
            })
            .render();
    }
}

#[myth::main]
fn main() -> myth::Result<()> {
    App::new()
        .with_title("Custom Post-FX Pass")
        .with_settings(RendererSettings {
            vsync: false,
            ..Default::default()
        })
        .run::<CustomPostFxDemo>()
}
