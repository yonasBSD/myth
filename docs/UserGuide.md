# Myth Engine User Guide

This guide explains how to build applications with the current Myth Rust API. It follows the same flow as the examples in this repository and assumes the top-level myth crate facade, not the older monolithic layout.

---

## 1. Mental Model

The current engine is easiest to understand as four cooperating layers:

1. App: window creation and event loop.
2. Engine: renderer, scene manager, asset server, and input state.
3. Scene: nodes, cameras, lights, environment, animation mixers.
4. Render graph: the per-frame pipeline assembled from the active scene.

In everyday code you usually start with:

```rust
use myth::prelude::*;
```

---

## 2. Project Setup

Add Myth to Cargo.toml:

```toml
[dependencies]
myth = { git = "https://github.com/panxinmiao/myth", branch = "main" }
env_logger = "0.11"
```

Feature flags worth deciding up front:

| Feature | When to enable it |
| --- | --- |
| gltf | Loading glTF and GLB assets |
| http | Pulling assets from HTTP sources |
| 3dgs | Rendering Gaussian splats |
| gaussian-npz | Loading compressed NPZ Gaussian clouds |
| debug_view | Debug visualizations and graph inspection helpers |

---

## 3. Your First App

```rust
use myth::prelude::*;

struct Demo;

impl AppHandler for Demo {
    fn init(engine: &mut Engine, _window: &dyn Window) -> Self {
        let scene = engine.scene_manager.create_active();

        let cube = scene.spawn_box(
            1.0,
            1.0,
            1.0,
            PhysicalMaterial::new(Vec4::new(1.0, 0.55, 0.25, 1.0))
                .with_roughness(0.35)
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
                node.transform.rotation *= Quat::from_rotation_y(dt);
            }
        });

        Self
    }
}

#[myth::main]
fn main() -> myth::Result<()> {
    env_logger::init();

    App::new()
        .with_title("Myth Hello World")
        .with_settings(RendererSettings {
            path: RenderPath::HighFidelity,
            ..Default::default()
        })
        .run::<Demo>()
}
```

What matters here:

- `scene.spawn_box(...)` comes from `SceneExt` and needs `&engine.assets`.
- rendering is skipped until `scene.active_camera` is set.
- `scene.on_update(...)` is the fastest way to attach simple per-scene logic.

---

## 4. Scene Construction Patterns

### Spawn helpers

For prototypes and examples, the helper methods are the most concise path:

```rust
let cube = scene.spawn_box(1.0, 1.0, 1.0, material, &engine.assets);
let sphere = scene.spawn_sphere(0.5, material, &engine.assets);
let ground = scene.spawn_plane(20.0, 20.0, material, &engine.assets);
let column = scene.spawn_cylinder(0.4, 2.5, material, &engine.assets);
let marker = scene.spawn_cone(0.35, 0.9, material, &engine.assets);
let ring = scene.spawn_torus(1.2, 0.2, material, &engine.assets);
```

### Manual resource registration

Use this when you want explicit control over asset reuse:

```rust
let geo = engine.assets.geometries.add(Geometry::new_box(1.0, 1.0, 1.0));
let mat = engine.assets.materials.add(PhysicalMaterial::default());
let node = scene.add_mesh(Mesh::new(geo, mat));
```

### Transforms and hierarchy

```rust
let parent = scene.spawn_box(1.0, 1.0, 1.0, material, &engine.assets);
let child = scene.spawn_sphere(0.35, material, &engine.assets);

scene.attach(child, parent);
scene.node(&parent).set_position(0.0, 1.0, 0.0);
scene.node(&child).set_position(1.0, 0.0, 0.0);
```

Use `scene.node(&handle)` for fluent setup and `scene.get_node_mut(handle)` when you need direct access to the transform or optional components.
Use `add_mesh`, `add_camera`, `add_light`, or the `spawn_*` helpers for root nodes. `create_node_with_name(...)` only creates a detached node handle; if you want an organizational node, attach it under an existing rooted node.

---

## 5. Cameras, Lights, and Environment

### Cameras

The usual setup is:

```rust
let camera = scene.add_camera(Camera::new_perspective(45.0, 16.0 / 9.0, 0.1));
scene.node(&camera).set_position(0.0, 2.0, 5.0).look_at(Vec3::ZERO);
scene.active_camera = Some(camera);
```

If you resize the window yourself in a custom loop, call `engine.resize(width, height)` so the active camera viewport stays in sync.
For scripted focus changes, `OrbitControls` already provides `set_target(...)`, `set_position(...)`, and `fit(...)`.

### Materials

For PBR surfaces, start with `PhysicalMaterial`. Refraction-heavy materials can now stay in builder style:

```rust
let glass = PhysicalMaterial::new(Vec4::new(0.96, 0.98, 1.0, 1.0))
    .with_ior(1.52)
    .with_roughness(0.03)
    .with_transmission(1.0, 0.35, 6.0, Vec3::ONE);
```

### Lights

Myth scenes typically mix one or more analytic lights with image-based lighting:

```rust
scene.add_light(Light::new_directional(Vec3::ONE, 5.0));
scene.add_light(Light::new_point(Vec3::new(1.0, 0.8, 0.6), 100.0, 0.0));
```

### Environment and sky

The current scene surface exposes:

- solid background color
- environment maps for IBL and skybox
- procedural sky parameters
- `DayNightCycle` for animated atmosphere setups

See [README.md](../README.md) and `examples/procedural_sky.rs` for the most up-to-date sky workflow.

---

## 6. Loading Assets

### Textures and HDR environments

The asset server owns texture lifetimes and loading state:

```rust
let albedo = engine.assets.load_texture("examples/assets/uv_grid.png", ColorSpace::Srgb, true);
let env = engine.assets.load_hdr_texture("examples/assets/studio.hdr");
scene.environment.set_env_map(Some(env));
```

### glTF

Current Rust examples generally follow this pattern:

```rust
let prefab = GltfLoader::load(path, engine.assets.clone())?;
let root = scene.instantiate(&prefab);
```

`SceneExt::instantiate` rebuilds the node hierarchy, binds skins, and installs animation mixers when the prefab carries animation clips.

### Animation playback

After instantiating a glTF scene, you can access its mixer on the returned root node. For working examples, use:

- `examples/morph_target.rs`
- `examples/skinning.rs`
- `examples/shadow_skinning.rs`

---

## 7. Choosing the Render Path

Myth currently has two topologies:

| Path | Best for |
| --- | --- |
| `RenderPath::BasicForward` | Lightweight forward scenes, lower-end devices, simple tools |
| `RenderPath::HighFidelity` | PBR, HDR, bloom, tone mapping, SSAO, TAA, procedural sky, 3DGS |

Practical rule: if you need any advanced post-processing or Gaussian splatting, use `RenderPath::HighFidelity`.

---

## 8. Custom Render Passes

Older documentation described a dedicated `compose_frame` app hook. The current API moved that work into `AppHandler::render()`.

Minimal custom render flow:

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

Use this pattern when you need:

- a custom fullscreen post effect
- a debug overlay inserted before or after built-in post-processing
- custom graph resources that should live inside the RDG lifetime model

Reference implementations:

- `examples/custom_post_fx.rs`
- `examples/procedural_sky.rs`

---

## 9. Custom Materials

Custom materials are implemented through `MaterialTrait` and used exactly like built-in materials once registered.

Relevant examples:

- `examples/custom_material.rs`
- `examples/custom_material_dissolve.rs`
- `examples/custom_material_triplanar.rs`
- `examples/custom_material_texture_flow.rs`

Use the built-in materials as a baseline, then move to `MaterialTrait` once you need custom shader defines, per-material uniforms, or different texture binding behavior.

---

## 10. 3D Gaussian Splatting

Myth now has a dedicated Gaussian splatting path integrated into the high-fidelity frame graph.

Enable the relevant features:

```toml
myth = { git = "https://github.com/panxinmiao/myth", branch = "main", features = ["3dgs", "gaussian-npz"] }
```

Minimal flow:

```rust
let cloud = engine.assets.load_gaussian_npz("examples/assets/3dgs/point_cloud.npz".into());
let node = scene.add_gaussian_cloud("gaussian_cloud", cloud);
scene.node(&node).set_rotation_euler(
    std::f32::consts::FRAC_PI_2,
    0.0,
    std::f32::consts::FRAC_PI_2,
);
```

Use `RenderPath::HighFidelity` for these scenes. The reference implementation is `examples/gaussian_splatting.rs`.

---

## 11. Headless and Offscreen Rendering

The engine now supports a first-class offscreen flow for tests, CI, exporters, and video pipelines.

Typical shape:

```rust
let mut engine = Engine::default();
engine.init_headless(1280, 720, None).await?;

// build scene
engine.update(1.0 / 60.0);
engine.render_active_scene();

let pixels = engine.readback_pixels()?;
```

For high-throughput capture, use `ReadbackStream` and the streaming helpers on `Engine` instead of synchronous per-frame readback.

Reference material:

- `examples/headless_export.rs`
- `tests/headless_test.rs`

---

## 12. Recommended Example Roadmap

If you are onboarding to the current codebase, read examples in this order:

1. `examples/box.rs`
2. `examples/box_pbr.rs`
3. `examples/helmet_gltf.rs`
4. `examples/custom_post_fx.rs`
5. `examples/procedural_sky.rs`
6. `examples/gaussian_splatting.rs`
7. `examples/headless_export.rs`

This order mirrors the engine's current architecture from basic scene setup through advanced frame-graph extension.

---

## 13. Common Pitfalls

- No active camera means `engine.compose_frame()` returns `None` and nothing is rendered.
- `SceneExt` spawn helpers require `&engine.assets`; older call patterns without the asset server are stale.
- If you need bloom, tone mapping, SSAO, procedural sky, or 3DGS, pick `RenderPath::HighFidelity` explicitly.
- In custom loops, call `engine.resize(...)` on window resize and `engine.maybe_prune()` after rendering.
- Treat the examples directory as the source of truth when older prose and code disagree.

---

## 14. Next References

- [API.md](API.md)
- [RenderGraph.md](RenderGraph.md)
- [README.md](../README.md)