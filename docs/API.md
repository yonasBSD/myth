# Myth Engine API Reference

This document tracks the current public Rust API exposed by the top-level myth crate. It is organized around the facade in src/lib.rs, so the names shown here match what downstream applications import today.

For deeper background on the render graph itself, see [RenderGraph.md](RenderGraph.md).

---

## API at a Glance

| Entry | Purpose | Notes |
| --- | --- | --- |
| `myth::prelude::*` | Everyday imports | Recommended for app code and examples |
| `myth::app` | Windowed application framework | Available with the winit feature |
| `myth::engine` | Window-agnostic engine core | Always available |
| `myth::scene` | Scene graph, cameras, lights, background, sky | Re-export of myth_scene |
| `myth::resources` | Geometry, material, texture, mesh, tone mapping settings | Re-export of myth_resources |
| `myth::assets` | Asset loading and SceneExt helpers | Re-export of myth_assets |
| `myth::animation` | Clips, tracks, mixers, rig binding | Re-export of myth_animation |
| `myth::render` | Renderer, FrameComposer, settings, low-level GPU access | High-level alias over myth_render |
| `myth::renderer` | Full renderer crate surface | Use when you need graph/core internals |
| `myth::utils` | Utility helpers | Currently includes OrbitControls |

The top-level crate also re-exports the most common types directly, including App, AppHandler, Engine, Scene, Camera, Light, Renderer, RenderPath, RendererSettings, Texture, PhysicalMaterial, PhongMaterial, UnlitMaterial, AssetServer, FrameComposer, OrbitControls, and the engine-wide Result alias.

---

## Quick Start

```rust
use myth::prelude::*;

struct MyApp;

impl AppHandler for MyApp {
    fn init(engine: &mut Engine, _window: &dyn Window) -> Self {
        let scene = engine.scene_manager.create_active();

        let cube = scene.spawn_box(
            1.0,
            1.0,
            1.0,
            PhysicalMaterial::new(Vec4::new(1.0, 0.45, 0.2, 1.0))
                .with_roughness(0.45)
                .with_metalness(0.0),
            &engine.assets,
        );

        scene.add_light(Light::new_directional(Vec3::ONE, 4.0));

        let camera = scene.add_camera(Camera::new_perspective(45.0, 16.0 / 9.0, 0.1));
        scene
            .node(&camera)
            .set_position(0.0, 1.5, 4.0)
            .look_at(Vec3::ZERO);
        scene.active_camera = Some(camera);

        scene.on_update(move |scene, _input, dt| {
            if let Some(node) = scene.get_node_mut(cube) {
                node.transform.rotation *= Quat::from_rotation_y(dt * 0.9);
            }
        });

        Self
    }
}

#[myth::main]
fn main() -> myth::Result<()> {
    App::new()
        .with_title("Myth Quick Start")
        .with_settings(RendererSettings {
            path: RenderPath::HighFidelity,
            ..Default::default()
        })
        .run::<MyApp>()
}
```

Key points from the current API:

- Primitive spawn helpers come from SceneExt and require &engine.assets.
- The active camera must be assigned through scene.active_camera.
- The default RendererSettings already use RenderPath::HighFidelity; set the path explicitly when you need deterministic behavior across Rust and Python entry points.

---

## Import Patterns

### Preferred: prelude

```rust
use myth::prelude::*;
```

The prelude includes application traits, scene types, common resources, asset handles, animation types, math types, and render settings.

### Explicit modules

```rust
use myth::app::{App, AppHandler, Window};
use myth::engine::{Engine, FrameState};
use myth::scene::{Camera, Light, Scene};
use myth::assets::{AssetServer, GltfLoader, SceneExt};
use myth::render::{FrameComposer, RenderPath, Renderer, RendererInitConfig, RendererSettings};
```

Use explicit modules when you are writing libraries or examples that want to show exactly where each type lives.

---

## Application Model

### App

App is the winit-backed builder used for standalone desktop and web applications.

```rust
let app = App::new()
    .with_title("My App")
    .with_init_config(RendererInitConfig::default())
    .with_settings(RendererSettings::default());
```

Current builder methods:

| Method | Purpose |
| --- | --- |
| `App::new()` | Create a builder with default title and render settings |
| `.with_title(...)` | Set window title |
| `.with_init_config(...)` | Configure static GPU initialization |
| `.with_settings(...)` | Configure runtime render path and presentation settings |
| `.with_inner_size(width, height)` | Native-only initial window size |
| `.with_canvas_id(...)` | WASM-only canvas selection |
| `.run::<H>()` | Start the event loop with an AppHandler |

### AppHandler

The lifecycle trait currently exposes four hooks:

```rust
pub trait AppHandler: Sized + 'static {
    fn init(engine: &mut Engine, window: &dyn Window) -> Self;

    fn on_event(
        &mut self,
        engine: &mut Engine,
        window: &dyn Window,
        event: &dyn std::any::Any,
    ) -> bool {
        false
    }

    fn update(&mut self, engine: &mut Engine, window: &dyn Window, frame: &FrameState) {}

    fn render(&mut self, engine: &mut Engine, window: &dyn Window) {
        engine.render_active_scene();
    }
}
```

Important drift from older docs: there is no compose_frame hook on the trait anymore. Advanced render customization now happens by overriding render() and calling engine.compose_frame() yourself.

### Window

Window is the platform-neutral abstraction passed into init, update, and render.

Current capabilities:

- set_title(&self, title: &str)
- inner_size(&self) -> Vec2
- scale_factor(&self) -> f32
- request_redraw(&self)
- set_cursor_visible(&self, visible: bool)
- as_any(&self) -> &dyn Any

---

## Engine Core

Engine is the window-agnostic coordinator shared by the Rust app layer, Python bindings, and headless/offscreen workflows.

Public fields that application code uses most often:

| Field | Purpose |
| --- | --- |
| renderer | Low-level renderer instance |
| scene_manager | Scene creation, activation, lookup |
| assets | Asset server and registries |
| input | Keyboard, mouse, wheel, and resize state |

Key methods:

| Method | Purpose |
| --- | --- |
| Engine::new(init, settings) | Create a configured engine |
| Engine::default() | Default RendererInitConfig + RendererSettings |
| engine.init(window, width, height).await | Initialize a surface-backed renderer |
| engine.init_headless(width, height, format).await | Initialize offscreen/headless rendering |
| engine.update(dt) | Advance asset loading, animations, scene logic, input frame state |
| engine.resize(width, height) | Resize surface and camera viewport |
| engine.compose_frame() | Prepare a FrameComposer for the active scene and active camera |
| engine.render_active_scene() | Default render path: compose + render |
| engine.maybe_prune() | Periodic renderer cleanup |
| engine.time() / engine.frame_count() / engine.size() | Frame timing and current output size |

### FrameState

Per-frame data passed into AppHandler::update:

```rust
pub struct FrameState {
    pub time: f32,
    pub dt: f32,
    pub frame_count: u64,
}
```

Use frame.dt for simulation and frame.time for procedural animation.

---

## Scene Graph and Asset-Aware Helpers

### Scene creation

The common path is:

```rust
let scene = engine.scene_manager.create_active();
```

Or, for explicit multi-scene management:

```rust
let handle = engine.scene_manager.create_scene();
engine.scene_manager.set_active(handle);
```

### SceneExt

SceneExt lives in myth_assets and is re-exported by the top-level crate. It provides the asset-aware helpers most examples use:

| Method | Purpose |
| --- | --- |
| instantiate(&Prefab) | Instantiate a glTF prefab into the scene |
| spawn(geometry, material, &assets) | Spawn a mesh node from any geometry/material combination |
| spawn_box(w, h, d, material, &assets) | Box primitive helper |
| spawn_sphere(radius, material, &assets) | Sphere primitive helper |
| spawn_plane(width, height, material, &assets) | Plane primitive helper |
| spawn_cylinder(radius, height, material, &assets) | Cylinder primitive helper |
| spawn_cone(radius, height, material, &assets) | Cone primitive helper |
| spawn_torus(radius, tube, material, &assets) | Torus primitive helper |

### Common scene operations

The current scene API surface is centered around node handles and component collections:

- scene.add_mesh(...)
- scene.add_camera(...)
- scene.add_light(...)
- scene.attach(child, parent)
- scene.node(&handle) for chainable transform edits
- scene.get_node_mut(handle) for direct mutation
- scene.active_camera = Some(handle) to select the render camera

Environment and background capabilities exposed by Scene include:

- background color and background mode
- skybox/environment map configuration
- DayNightCycle and ProceduralSkyParams
- bloom, tone mapping, SSAO, and debug-view state stored on the scene itself

### Cameras and lights

Primary scene-facing types:

- Camera
- ProjectionType
- Light
- LightKind
- BackgroundSettings
- ProceduralSkyParams
- DayNightCycle

The active camera is required before engine.compose_frame() or engine.render_active_scene() can produce a frame.

---

## Resources and Materials

The myth::resources facade exports the resource structs used for CPU-side scene description.

Frequently used types:

| Category | Types |
| --- | --- |
| Geometry | Geometry, Attribute, VertexFormat, IndexFormat |
| Mesh | Mesh |
| Materials | Material, PhysicalMaterial, PhongMaterial, UnlitMaterial, MaterialTrait, RenderableMaterialTrait |
| Textures and images | Texture, Image, TextureSlot, TextureTransform |
| Rendering settings | ToneMappingMode, ToneMappingSettings, AgxLook, AntiAliasingMode, FxaaSettings, TaaSettings |
| Primitive generators | create_box, create_plane, create_sphere, create_cylinder, create_cone, create_torus, PlaneOptions, SphereOptions, CylinderOptions, ConeOptions, TorusOptions |

Notes for current code:

- PhysicalMaterial is the default choice for PBR scenes.
- PhysicalMaterial now includes a builder-style `with_ior(...)` helper for refraction workflows, alongside the lower-level mutable accessors generated by the material macro.
- OrbitControls already exposes `set_target(...)`, `set_position(...)`, and `fit(...)` for programmatic camera reframing.
- Custom materials are implemented through MaterialTrait; see examples/custom_material.rs and the related example variants for current patterns.
- Texture and Image are CPU-side assets. GPU allocation and residency are handled through the asset server and renderer.

---

## Asset Loading

AssetServer is the central registry for geometry, material, texture, prefab, and optional Gaussian cloud assets.

Current top-level exports include:

- AssetServer
- handle types such as GeometryHandle, MaterialHandle, TextureHandle, ImageHandle, PrefabHandle, GaussianCloudHandle
- AssetSource, ColorSpace, GeometryQuery, ResolveGeometry, ResolveMaterial
- SceneExt
- GltfLoader under the gltf feature

### glTF

Typical loading patterns:

```rust
let prefab = GltfLoader::load(path, engine.assets.clone())?;
let root = scene.instantiate(&prefab);
```

or via higher-level example code that wraps the same flow.

### 3D Gaussian Splatting

Feature-gated exports:

| Feature | Exports |
| --- | --- |
| 3dgs | GaussianCloud, load_gaussian_ply, load_gaussian_ply_from_source_async, scene Gaussian integration |
| gaussian-npz | load_gaussian_npz, load_gaussian_npz_from_source_async |

Current examples use:

```rust
let cloud = engine.assets.load_gaussian_npz("examples/assets/3dgs/point_cloud.npz".into());
let node = scene.add_gaussian_cloud("gaussian_cloud", cloud);
```

3DGS is designed for the high-fidelity frame graph and should be paired with RenderPath::HighFidelity.

---

## Animation

The animation facade exports:

- AnimationClip
- AnimationAction
- AnimationMixer
- AnimationSystem
- LoopMode
- InterpolationMode
- Rig, Binder, ClipBinding, Track, TrackBinding, TrackData, TrackMeta

When a glTF prefab contains animations, SceneExt::instantiate builds a mixer for the returned root node and binds the available clips to that node hierarchy.

Examples to reference:

- examples/morph_target.rs
- examples/skinning.rs
- examples/shadow_skinning.rs

---

## Rendering and Render Graph Integration

### RenderPath

Myth currently ships two pipeline topologies:

| Path | Use case |
| --- | --- |
| RenderPath::BasicForward | Lightweight forward LDR rendering |
| RenderPath::HighFidelity | HDR + post-processing + advanced graph features |

RenderPath::HighFidelity is the default RendererSettings value and the path used by advanced examples such as bloom, procedural sky, custom post-processing, and Gaussian splatting.

### RendererInitConfig and RendererSettings

RendererInitConfig controls static GPU initialization inputs such as backend selection, power preference, required features/limits, and depth format.

RendererSettings is runtime-mutable and currently exposes:

- path: RenderPath
- vsync: bool
- anisotropy_clamp: u16

### FrameComposer

Engine::compose_frame() returns `Option<FrameComposer<'_>>`. It returns None when there is no active scene or active camera. Once you have a composer, the standard flow is:

```rust
let Some(composer) = engine.compose_frame() else {
    return;
};

composer.render();
```

To inject custom passes, override `AppHandler::render()` and work on the composer directly:

```rust
fn render(&mut self, engine: &mut Engine, _window: &dyn Window) {
    use myth::renderer::graph::core::HookStage;

    let Some(composer) = engine.compose_frame() else {
        return;
    };

    composer
        .add_custom_pass(HookStage::BeforePostProcess, move |_rdg, blackboard| {
            blackboard
        })
        .render();
}
```

For RDG-owned scene lighting, use the dedicated GPU local-light injection hook. It runs before clustered lighting and forward shading consume the frame's final local-light buffers:

```rust
use myth::renderer::graph::composer::GpuLightBuffers;

composer
    .inject_gpu_local_lights(|ctx| {
        if gpu_swarm_disabled {
            return None;
        }

        Some(ctx.graph.add_pass("GpuSwarmLights", |builder| {
            let gpu_light_metadata = builder.create_buffer("Gpu_Light_Metadata", /* ... */);
            let gpu_light_storage = builder.create_buffer("Gpu_Light_Storage", /* ... */);
            let gpu_light_count = builder.create_buffer("Gpu_Light_Count", /* ... */);

            (
                GpuSwarmLightPassNode { /* ... */ },
                GpuLightBuffers {
                    light_metadata: gpu_light_metadata,
                    light_storage: gpu_light_storage,
                    indirect_count_buffer: Some(gpu_light_count),
                },
            )
        }))
    })
    .render();
```

`inject_gpu_local_lights(...)` only injects the optional GPU local-light track. CPU directional lights and their shadow data remain in the global scene bindings, while CPU point and spot lights keep flowing through the engine's extracted local-light path. The clustered-lighting feature now performs the smart routing internally: if the hook returns `None`, the renderer stays on the original CPU-only path; if CPU local lights are absent, the injected GPU lights are forwarded directly; otherwise the engine runs its built-in safe merge pass and exposes the merged buffers to both clustered lighting and forward shading. `GpuLightBuffers` contains the local-light metadata buffer, the local-light storage buffer, and an optional indirect-count buffer. When the count buffer is present, Myth can derive `dispatch_workgroups_indirect` arguments on-GPU for clustered light preprocessing.

See examples/custom_post_fx.rs, examples/procedural_sky.rs, and examples/gpu_driven_particle_lights.rs for complete, current examples.

### Low-level GPU access

myth::render::core re-exports:

- WgpuContext
- ResourceManager
- BindingResource, Bindings, ResourceBuilder
- ReadbackStream, ReadbackFrame, ReadbackError

Use these when building custom render passes or headless readback flows.

---

## Headless and Readback APIs

Myth's headless path is now a first-class part of the engine API.

Primary engine-level methods:

| Method | Purpose |
| --- | --- |
| init_headless(width, height, format) | Create an offscreen renderer |
| readback_pixels() | Read a single tightly packed frame |
| submit_to_stream(&mut ReadbackStream) | Non-blocking ring-buffer submission |
| submit_to_stream_blocking(&mut ReadbackStream) | Back-pressure friendly submission |
| flush_stream(&mut ReadbackStream) | Drain all in-flight frames |
| poll_device() | Drive pending GPU callbacks |

This is the API surface used by tests and by the Python headless bindings.

---

## Feature Flags

Important crate features visible from the current facade:

| Feature | Default | Effect |
| --- | --- | --- |
| winit | yes | Enables the windowed App entry point |
| gltf | yes | Enables glTF loading and GltfLoader |
| http | yes | Enables HTTP asset loading |
| gltf-meshopt | no | Enables meshopt-compressed glTF assets |
| debug_view | no | Enables debug-view scene settings exports |
| rdg_inspector | no | Enables render-graph inspection helpers |
| 3dgs | no | Enables Gaussian splatting support |
| gaussian-npz | no | Enables NPZ Gaussian loading on top of 3dgs |

---

## Example Map

These examples reflect the current public API better than older prose docs:

| Example | Coverage |
| --- | --- |
| examples/hello_triangle.rs | Minimal renderer/bootstrap |
| examples/box.rs and examples/box_pbr.rs | Primitive spawning and material setup |
| examples/helmet_gltf.rs and examples/sponza.rs | glTF loading and scene composition |
| examples/custom_material.rs | Custom material pipeline |
| examples/custom_post_fx.rs | AppHandler::render + FrameComposer::add_custom_pass |
| examples/procedural_sky.rs | Atmosphere, sky, and post-graph injection |
| examples/gaussian_splatting.rs | 3DGS integration |
| examples/headless_export.rs | Headless/offscreen rendering |

---

## Related Documents

- [UserGuide.md](UserGuide.md)
- [RenderGraph.md](RenderGraph.md)
- [RenderGraph_zh.md](RenderGraph_zh.md)
- [README.md](../README.md)