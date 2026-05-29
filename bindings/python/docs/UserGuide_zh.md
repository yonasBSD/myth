# Myth Engine Python 用户指南

本指南基于当前 myth Python 绑定的真实公开接口编写，并以 bindings/python/examples 下的示例作为参照。

如果你需要查精确签名和属性名，请配合 [API_zh.md](API_zh.md) 阅读。

---

## 1. 运行模型

当前 Python API 最容易按下面五层理解：

1. App：内置窗口和事件循环。
2. Renderer：外部窗口或 headless 运行时。
3. Engine：回调期间用于建场景和加载资产的代理。
4. Scene：当前活动场景的相机、灯光、环境与动画入口。
5. Object3D：带变换助手和组件代理的场景节点句柄。

先记住两条规则：

- App 和 Renderer 在不传 render_path 时默认走基础渲染路径。
- bloom、色调映射、SSAO、SSGI、SSR、Gaussian splatting 这类能力应显式使用 RenderPath.HIGH_FIDELITY。

---

## 2. 安装

### 直接安装

```bash
pip install myth-py
```

### 从源码构建

```bash
git clone https://github.com/panxinmiao/myth.git
cd myth/bindings/python
pip install maturin
maturin develop --release
```

当前绑定面向 Python 3.10+。

---

## 3. 用 App 快速启动

App 是最直接的入口。

```python
import myth

app = myth.App(
    title="Myth Python Quickstart",
    render_path=myth.RenderPath.HIGH_FIDELITY,
)

orbit = myth.OrbitControls(position=[0.0, 2.0, 5.0], target=[0.0, 0.0, 0.0])
camera_node = None
cube_node = None


@app.init
def on_init(ctx: myth.Engine) -> None:
    global camera_node, cube_node

    scene = ctx.create_scene()

    cube_node = scene.add_mesh(
        myth.BoxGeometry(width=1.0, height=1.0, depth=1.0),
        myth.PhysicalMaterial(color="#ff7a33", roughness=0.35, metalness=0.0),
    )

    camera_node = scene.add_camera(myth.PerspectiveCamera(fov=45.0, near=0.1))
    camera_node.position = [0.0, 1.5, 4.0]
    camera_node.look_at([0.0, 0.0, 0.0])
    scene.active_camera = camera_node

    sun = scene.add_light(myth.DirectionalLight(color=[1.0, 1.0, 1.0], intensity=4.0))
    sun.position = [4.0, 6.0, 2.0]
    sun.look_at([0.0, 0.0, 0.0])

    scene.set_background_color(0.08, 0.09, 0.12)


@app.update
def on_update(ctx: myth.Engine, frame: myth.FrameState) -> None:
    orbit.update(camera_node, frame.dt)
    cube_node.rotate_y(frame.dt)


app.run()
```

这里最关键的是：

- 在 @app.init 中创建场景
- 在渲染前设置 scene.active_camera
- 用 frame.dt 驱动动画与控制器
- 需要后处理时显式选择 RenderPath.HIGH_FIDELITY

---

## 4. 场景构建

### 网格

通过 Scene.add_mesh(...) 传入几何体与材质对象：

```python
box = scene.add_mesh(
    myth.BoxGeometry(1.0, 1.0, 1.0),
    myth.PhysicalMaterial(color="#ff7a33", roughness=0.35),
)

sphere = scene.add_mesh(
    myth.SphereGeometry(radius=0.5, width_segments=32, height_segments=16),
    myth.PhongMaterial(color="#66c7ff", shininess=48.0),
)
```

内置几何体类型：

- BoxGeometry
- SphereGeometry
- PlaneGeometry
- Geometry，用于自定义顶点/索引数据

内置材质类型：

- UnlitMaterial
- PhongMaterial
- PhysicalMaterial

### 相机与灯光

相机和灯光都挂在 Object3D 节点上：

```python
camera = scene.add_camera(myth.PerspectiveCamera(fov=45.0, near=0.1))
camera.position = [0.0, 1.5, 4.0]
camera.look_at([0.0, 0.0, 0.0])
scene.active_camera = camera

sun = scene.add_light(myth.DirectionalLight(intensity=4.0))
sun.position = [4.0, 6.0, 2.0]
sun.look_at([0.0, 0.0, 0.0])
```

如果没有给 scene.active_camera 赋值，场景逻辑会照常运行，但不会有任何画面输出。

### 背景、环境与后处理

当前 Scene 上常用的便捷方法包括：

- set_background_color(r, g, b)
- set_environment_map(texture)
- set_environment_intensity(value)
- set_ambient_light(r, g, b)
- set_bloom(...)
- set_tone_mapping(...)
- set_ssao_*...

典型的高保真设置：

```python
scene.set_background_color(0.04, 0.05, 0.08)
scene.set_bloom(True, strength=0.05, radius=0.004)
scene.set_tone_mapping("agx", exposure=1.0)
scene.set_ssao_enabled(True)
```

### 变换约定

Object3D 同时暴露弧度和角度接口，但两者不可混用：

- node.rotation 用弧度。
- node.rotation_euler 用角度。

常用助手：

- set_uniform_scale(...)
- rotate_x(...)、rotate_y(...)、rotate_z(...)
- rotate_world_x(...)、rotate_world_y(...)、rotate_world_z(...)
- look_at(...)

### OrbitControls

OrbitControls 直接控制相机节点：

```python
orbit = myth.OrbitControls(position=[0.0, 2.0, 5.0], target=[0.0, 0.0, 0.0])

@app.update
def on_update(ctx: myth.Engine, frame: myth.FrameState) -> None:
    orbit.update(camera_node, frame.dt)
```

控制器接收的是相机对应的 Object3D，不是相机组件代理。

### 组件代理

节点可直接暴露实时组件代理：

```python
if camera.camera:
    camera.camera.fov = 55.0

if sun.light:
    sun.light.intensity = 6.0

if cube_node.mesh:
    cube_node.mesh.cast_shadows = True
```

这是在节点创建之后继续微调相机、灯光和网格组件的推荐方式。

---

## 5. 资产加载

### 普通纹理与 HDR 环境贴图

```python
albedo = ctx.load_texture("assets/albedo.png", color_space="srgb", generate_mipmaps=True)
normal = ctx.load_texture("assets/normal.png", color_space="linear", generate_mipmaps=True)
hdr = ctx.load_hdr_texture("assets/studio.hdr")

scene.set_environment_map(hdr)
scene.set_environment_intensity(1.0)
```

颜色纹理用 srgb，法线贴图等数据纹理用 linear。

### glTF 与动画

```python
root = ctx.load_gltf("assets/helmet.glb")
scene.play_if_any_animation(root)
```

Scene 上的动画助手：

- play_animation(node, name)
- play_if_any_animation(node)
- list_animations(node)
- get_animation_mixer(node)

参考示例：

- [../examples/gltf_viewer.py](../examples/gltf_viewer.py)
- [../examples/sponza.py](../examples/sponza.py)
- [../examples/morph.py](../examples/morph.py)

### 动态纹理

当前绑定已经直接提供视频帧、CPU 特效和 GUI 表面的动态纹理工作流：

```python
texture = ctx.create_dynamic_texture(
    "video-frame",
    width,
    height,
    initial_rgba_bytes,
    color_space="srgb",
)

texture.update_data(next_rgba_bytes)
```

支持的缓冲包括：

- bytes
- bytearray
- memoryview
- NumPy 等提供的 C 连续 uint8 RGBA 缓冲

参考示例：

- [../examples/video_texture.py](../examples/video_texture.py)

### 3D Gaussian Splatting

绑定层现在已经直接暴露 Gaussian cloud 加载与挂场景能力：

```python
cloud = ctx.load_gaussian_npz("assets/point_cloud.npz")
cloud.color_space = "linear"

node = scene.add_gaussian_cloud("gaussian_cloud", cloud)
node.rotation_euler = [90.0, 0.0, 0.0]
```

这类场景应使用 RenderPath.HIGH_FIDELITY。

参考示例：

- [../examples/gaussian_splatting.py](../examples/gaussian_splatting.py)

---

## 6. Renderer 模式与外部窗口

当窗口由别的 GUI 框架持有时，使用 Renderer。

```python
import myth

renderer = myth.Renderer(render_path=myth.RenderPath.HIGH_FIDELITY)
renderer.init_with_handle(window_handle, width, height)

scene = renderer.create_scene()

while running:
    process_events()
    renderer.inject_mouse_move(mouse_x, mouse_y)
    renderer.frame(1.0 / 60.0)

renderer.dispose()
```

此模式下你需要自己负责：

- 在窗口尺寸变化时调用 renderer.resize(width, height)
- 用 inject_* 方法转发键盘和鼠标事件
- 通过 update()、render() 或 frame() 自己驱动主循环

参考示例：

- [../examples/glfw_demo.py](../examples/glfw_demo.py)
- [../examples/pyside_demo.py](../examples/pyside_demo.py)
- [../examples/rendercanvas_demo.py](../examples/rendercanvas_demo.py)

---

## 7. Headless 渲染与回读

### 简单离屏渲染

```python
renderer = myth.Renderer(render_path=myth.RenderPath.HIGH_FIDELITY)
renderer.init_headless(1280, 720)

scene = renderer.create_scene()
# 构建场景

renderer.frame(1.0 / 60.0)
pixels = renderer.readback_pixels()
renderer.dispose()
```

这条路径适合导出器、测试和一次性截图。

参考示例：

- [../examples/headless_simple_test.py](../examples/headless_simple_test.py)
- [../examples/headless_readback_test.py](../examples/headless_readback_test.py)

### 流式回读

连续抓帧时使用 ReadbackStream：

```python
renderer = myth.Renderer(render_path=myth.RenderPath.HIGH_FIDELITY)
renderer.init_headless(1280, 720)

stream = renderer.create_readback_stream(buffer_count=3, max_stash_size=64)
buffer = bytearray(stream.frame_byte_size)

while running:
    renderer.frame(1.0 / 60.0)
    stream.try_submit(renderer)
    renderer.poll_device()

    frame_index = stream.try_recv_into(buffer)
    if frame_index is not None:
        consume(buffer, frame_index)

for frame in stream.flush(renderer):
    consume(frame["pixels"], frame["frame_index"])
```

参考示例：

- [../examples/headless_stream_test.py](../examples/headless_stream_test.py)

---

## 8. 输入与逐帧逻辑

FrameState 暴露当前帧时序信息：

- frame.delta_time 与 frame.dt
- frame.elapsed 与 frame.time
- frame.frame_count

Engine.input 和 Renderer.input 暴露输入状态代理。外部窗口模式下，需要靠 Renderer 的 inject_* 方法把事件灌进去。

典型模式：

```python
@app.update
def on_update(ctx: myth.Engine, frame: myth.FrameState) -> None:
    if ctx.input.key_down("Space"):
        print("space pressed")

    if ctx.input.mouse_button("Left"):
        dx, dy = ctx.input.mouse_delta()

    cube_node.rotate_y(frame.dt)
```

---

## 9. 示例阅读顺序

下面这些示例最贴近当前公开绑定接口：

| 示例 | 覆盖内容 |
| --- | --- |
| [../examples/demo.py](../examples/demo.py) | 基础场景、网格创建、轨道控制 |
| [../examples/earth.py](../examples/earth.py) | 纹理与分层场景构建 |
| [../examples/bloom_demo.py](../examples/bloom_demo.py) | 高保真后处理 |
| [../examples/video_texture.py](../examples/video_texture.py) | 动态纹理更新 |
| [../examples/gaussian_splatting.py](../examples/gaussian_splatting.py) | Gaussian splatting |
| [../examples/shadows.py](../examples/shadows.py) | 灯光与阴影开关 |
| [../examples/gltf_viewer.py](../examples/gltf_viewer.py) | 通用 GLB 查看器 |
| [../examples/glfw_demo.py](../examples/glfw_demo.py) | 外部窗口集成 |
| [../examples/pyside_demo.py](../examples/pyside_demo.py) | Qt 嵌入 |
| [../examples/rendercanvas_demo.py](../examples/rendercanvas_demo.py) | rendercanvas 嵌入 |
| [../examples/headless_simple_test.py](../examples/headless_simple_test.py) | 最小离屏渲染 |
| [../examples/headless_stream_test.py](../examples/headless_stream_test.py) | 流式回读 |

---

## 10. 常见问题

- 没有活动相机时，场景会更新但不会出图。
- rotation 是弧度，rotation_euler 是角度。
- 如果省略 render_path，App 与 Renderer 默认都是基础渲染路径。
- TextureHandle.update_data(...) 只对 create_dynamic_texture(...) 创建出来的纹理有效。
- 外部窗口模式下忘记 renderer.resize(...) 或忘记输入注入，通常会表现成视口或相机异常。
- headless 流式回读循环里记得调用 renderer.poll_device()，否则完成的帧不会及时变为可接收状态。