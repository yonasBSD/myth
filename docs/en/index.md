---
# https://vitepress.dev/reference/default-theme-home-page
layout: home

hero:
  name: "Myth Engine"
  text: "Next-Gen Rendering in Rust"
  tagline: A lightweight, cross-platform graphics architecture on wgpu · SSA RenderGraph compiler · Native 3D Gaussian Splatting
  image:
    src: /images/hero.jpg
    alt: Myth Engine Hero Image
  actions:
    - theme: brand
      text: Quick Start
      link: /en/guide/quick-start
    - theme: alt
      text: Feature Overview
      link: /en/guide/features
    - theme: alt
      text: Live Gallery
      link: https://panxinmiao.github.io/myth
    - theme: alt
      text: GitHub
      link: https://github.com/panxinmiao/myth

features:
  - icon: 🦀
    title: Pure Rust Core
    details: No GC overhead, memory-safe, zero-cost abstractions. Built on wgpu with Vulkan / Metal / DX12 / WebGPU backends.
  - icon: ⚙️
    title: SSA RenderGraph Compiler
    details: Declarative RenderGraph with automatic topological sort, dead-pass elimination and aggressive memory aliasing — ~1.6µs per-frame compile, zero manual barriers.
  - icon: 💡
    title: GPU-Driven Clustered Lighting
    details: Compute-driven clustered forward lighting for hundreds of dynamic point / spot lights, with GPU-generated light injection.
  - icon: ✨
    title: Full PBR & Post-Processing
    details: Clearcoat, Iridescence, Transmission, Sheen, Anisotropy; Bloom, TAA / FXAA / MSAA, SSAO / SSR / SSGI / SSSS.
  - icon: 🌌
    title: Native 3D Gaussian Splatting
    details: First-class hybrid 3DGS pipeline with GPU radix sort + indirect drawing, deeply fused with PBR geometry in a physically-correct color space.
  - icon: 🌅
    title: Procedural Sky & Atmosphere
    details: Physically-based atmospheric scattering (Hillaire 2020) with sun, moon, stars and a built-in DayNightCycle component.
  - icon: 🖥️
    title: Headless & Offscreen Rendering
    details: Runs without a window, with a built-in non-blocking GPU→CPU readback ring buffer for CI, cloud rendering and offline video.
  - icon: 🌐
    title: One Codebase, Every Platform
    details: Native desktop / mobile + WebGPU/WASM browsers + Python bindings, from production to scientific visualization.
---

<div style="max-width: 960px; margin: 48px auto 0; padding: 0 24px;">

## Render Your First Scene in Under 50 Lines

```rust
use myth::prelude::*;

struct MyApp;

impl AppHandler for MyApp {
    fn init(engine: &mut Engine, _: &dyn Window) -> Self {
        let scene = engine.scene_manager.create_active();

        // A spinning cube with a checkerboard texture
        let tex = engine.assets.checkerboard(512, 64);
        let cube = scene.spawn_box(
            1.0, 1.0, 1.0,
            PhongMaterial::new(Vec4::new(1.0, 0.76, 0.33, 1.0)).with_map(tex),
            &engine.assets,
        );

        let cam = scene.add_camera(Camera::new_perspective(45.0, 16.0 / 9.0, 0.1));
        scene.node(&cam).set_position(0.0, 0.0, 5.0).look_at(Vec3::ZERO);
        scene.active_camera = Some(cam);

        scene.add_light(Light::new_directional(Vec3::ONE, 5.0));

        scene.on_update(move |scene, _input, _dt| {
            if let Some(node) = scene.get_node_mut(cube) {
                node.transform.rotation *= Quat::from_rotation_y(0.02);
            }
        });

        Self {}
    }
}

#[myth::main]
fn main() -> myth::Result<()> {
    App::new().with_title("Hello Myth").run::<MyApp>()
}
```

> 📢 **Status: Beta** — The core architecture is stable and ready for real-world use. APIs are still evolving, and occasional breaking changes may occur.

</div>
