---
# https://vitepress.dev/reference/default-theme-home-page
layout: home

hero:
  name: "Myth Engine"
  text: "用 Rust 打造的下一代渲染引擎"
  tagline: 基于 wgpu 的轻量级跨平台图形架构 · SSA 渲染图编译器 · 原生 3D 高斯溅射
  image:
    src: /images/hero.jpg
    alt: Myth Engine Hero Image
  actions:
    - theme: brand
      text: 快速开始
      link: /guide/quick-start
    - theme: alt
      text: 核心特性
      link: /guide/features
    - theme: alt
      text: 在线 Gallery
      link: https://panxinmiao.github.io/myth
    - theme: alt
      text: GitHub
      link: https://github.com/panxinmiao/myth

features:
  - icon: 🦀
    title: 纯粹的 Rust 核心
    details: 无 GC 负担，内存安全，零成本抽象。基于 wgpu 同时支持 Vulkan / Metal / DX12 / WebGPU 后端。
  - icon: ⚙️
    title: SSA 渲染图编译器
    details: 声明式 RenderGraph，自动拓扑排序、死节点剔除与激进内存别名。单帧编译仅约 1.6µs，无需手动屏障。
  - icon: 💡
    title: GPU-Driven 聚类光照
    details: Compute 驱动的聚类前向光照，轻松驱动成百上千个动态点光源 / 聚光灯，并支持 GPU 生成光源注入。
  - icon: ✨
    title: 完整的 PBR 与后处理
    details: Clearcoat、Iridescence、Transmission、Sheen、Anisotropy；Bloom、TAA / FXAA / MSAA、SSAO / SSR / SSGI / SSSS。
  - icon: 🌌
    title: 原生 3D 高斯溅射
    details: 作为一等公民的 3DGS 混合管线，GPU 基数排序 + 间接绘制，与 PBR 几何在物理正确的色彩空间下深度融合。
  - icon: 🌅
    title: 程序化天空与大气
    details: 基于 Hillaire 2020 的物理大气散射，内置日月星辰与 DayNightCycle 昼夜循环组件。
  - icon: 🖥️
    title: 无头与离屏渲染
    details: 无需窗口即可运行，内置非阻塞的 GPU→CPU 回读环形缓冲，适用于 CI、云渲染与离线视频生成。
  - icon: 🌐
    title: 一套代码，全平台运行
    details: 原生桌面 / 移动端 + WebGPU/WASM 浏览器 + Python 绑定，覆盖从生产到科研可视化的完整场景。
---

<div style="max-width: 960px; margin: 48px auto 0; padding: 0 24px;">

## 不到 50 行代码，渲染你的第一个场景

```rust
use myth::prelude::*;

struct MyApp;

impl AppHandler for MyApp {
    fn init(engine: &mut Engine, _: &dyn Window) -> Self {
        let scene = engine.scene_manager.create_active();

        // 带棋盘格纹理、不断旋转的立方体
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

> 📢 **当前状态：Beta** —— 核心架构稳定，可用于真实项目；API 仍在演进，偶有破坏性变更。

</div>