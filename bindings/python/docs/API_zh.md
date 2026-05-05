# Myth Engine Python API 参考

本文档描述 bindings/python/src 当前实现并通过 myth 模块与 myth/__init__.pyi 暴露出来的公开 Python 绑定能力面。

如果你想看工作流和实践示例，请配合 [UserGuide_zh.md](UserGuide_zh.md) 一起阅读。

---

## 模块概览

| 入口 | 用途 |
| --- | --- |
| myth.App | 内置窗口和事件循环 |
| myth.Renderer | 外部窗口或 headless 渲染入口 |
| myth.Engine | 回调期间可用的引擎代理 |
| myth.Scene | 当前活动场景的创建与设置入口 |
| myth.Object3D | 带变换助手的场景节点句柄 |
| myth.TextureHandle | 纹理句柄，也用于动态纹理更新 |
| myth.ReadbackStream | 高吞吐 headless 回读流 |
| myth.GaussianCloud | 已加载但尚未挂入场景的 3DGS 资产 |
| myth.OrbitControls | 相机轨道控制器 |

当前绑定的几个关键约定：

- rotation 使用弧度。
- rotation_euler 使用角度。
- FrameState 同时暴露 delta_time 与别名 dt，以及 elapsed 与别名 time。
- App 和 Renderer 在未显式指定时默认使用基础渲染路径。

---

## RenderPath

```python
myth.RenderPath.BASIC
myth.RenderPath.HIGH_FIDELITY
```

| 值 | 含义 |
| --- | --- |
| RenderPath.BASIC | 前向 LDR 路径 |
| RenderPath.HIGH_FIDELITY | HDR 与后处理路径 |

绑定层仍兼容旧字符串，如 "basic"、"hdr"、"high_fidelity"，但新代码应优先使用枚举。

如果需要 bloom、色调映射、SSAO 或 Gaussian splatting，请显式使用 HIGH_FIDELITY。

---

## ClusteredShadingMode

```python
myth.ClusteredShadingMode.force_off()
myth.ClusteredShadingMode.force_on()
myth.ClusteredShadingMode.auto(threshold=16)
```

| 模式 | 含义 |
| --- | --- |
| `force_off()` | 永远使用普通 forward 光照循环 |
| `force_on()` | 永远启用 clustered lighting compute passes |
| `auto(threshold=N)` | 当场景灯光数量达到 `N` 时切换到 clustered 路径 |

---

## App

App 是最高层入口。

```python
app = myth.App(
    title="Myth Engine",
    render_path=myth.RenderPath.HIGH_FIDELITY,
    vsync=True,
    clustered_shading=myth.ClusteredShadingMode.auto(20),
    clear_color=[0.1, 0.1, 0.1, 1.0],
)
```

核心成员：

| 成员 | 类型 | 说明 |
| --- | --- | --- |
| title | str | 窗口标题 |
| render_path | str | RenderPath | 未显式设置时默认走基础路径 |
| clustered_shading | str | ClusteredShadingMode | 控制普通 forward 与 clustered 路由 |
| vsync | bool | 呈现同步开关 |
| clear_color | ColorInput | 包装层清屏颜色；可见背景通常用 scene.set_background_color(...) 设置 |

装饰器工作流：

```python
@app.init
def on_init(ctx: myth.Engine) -> None:
    ...

@app.update
def on_update(ctx: myth.Engine, frame: myth.FrameState) -> None:
    ...

app.run()
```

Engine 上下文只在 @app.init 与 @app.update 回调中有效。

---

## Renderer

Renderer 暴露引擎能力，但不拥有窗口。适合 GLFW、Qt、rendercanvas 或纯 headless 管线。

```python
renderer = myth.Renderer(
    render_path=myth.RenderPath.HIGH_FIDELITY,
    vsync=True,
    clustered_shading=myth.ClusteredShadingMode.force_on(),
)
```

初始化方法：

| 方法 | 用途 |
| --- | --- |
| init_with_handle(window_handle, width, height) | 绑定一个原生窗口句柄 |
| init_headless(width, height, format=None) | 启动离屏渲染器 |
| dispose() | 释放 GPU 资源 |

帧控制方法：

| 方法 | 用途 |
| --- | --- |
| update(dt=None) | 推进时间与场景逻辑 |
| render() | 渲染一帧 |
| frame(dt=None) | update() + render() |
| resize(width, height) | 通知新的输出尺寸 |

从 Engine 镜像过来的场景与资产方法：

- create_scene()
- active_scene()
- load_texture(...)
- create_dynamic_texture(...)
- load_hdr_texture(...)
- load_gltf(...)

外部窗口输入注入方法：

- inject_key_down(key)
- inject_key_up(key)
- inject_mouse_move(x, y)
- inject_mouse_down(button)
- inject_mouse_up(button)
- inject_scroll(dx, dy)

只读运行时属性：

- time
- frame_count
- input

---

## Engine

Engine 是传入 App 回调的代理对象。

只读属性：

| 属性 | 含义 |
| --- | --- |
| time | 当前累计时间，单位秒 |
| frame_count | 已处理帧数 |
| input | 输入状态代理 |

主要方法：

| 方法 | 用途 |
| --- | --- |
| create_scene() | 创建并激活一个场景 |
| active_scene() | 获取当前活动场景 |
| load_texture(path, color_space="srgb", generate_mipmaps=True) | 加载普通图像纹理 |
| create_dynamic_texture(name, width, height, data, color_space="srgb", generate_mipmaps=False) | 创建可更新的 RGBA 动态纹理 |
| load_hdr_texture(path) | 加载 HDR 环境纹理 |
| load_gltf(path) | 加载并实例化 glTF/GLB 到当前场景 |
| load_gaussian_ply(path) | 从 PLY 加载 Gaussian splat 云 |
| load_gaussian_npz(path) | 从 NPZ 加载 Gaussian splat 云 |
| set_title(title) | 在 App 模式下更新窗口标题 |

一旦 Renderer 完成初始化，它也会暴露同样的场景创建与资产加载接口。

---

## FrameState

FrameState 会传给 @app.update。

| 属性 | 别名 | 含义 |
| --- | --- | --- |
| delta_time | dt | 距离上一帧经过的秒数 |
| elapsed | time | 从启动到当前的总秒数 |
| frame_count | 无 | 累计帧索引 |

---

## Scene

Scene 是当前活动场景的代理。

### 核心节点创建

| 方法 | 返回值 |
| --- | --- |
| add_mesh(geometry, material) | Object3D |
| add_camera(camera) | Object3D |
| add_light(light) | Object3D |
| add_gaussian_cloud(name, cloud) | Object3D |
| attach(child, parent) | None |
| find_node_by_name(name) | Object3D | None |

### 活动相机

```python
scene.active_camera = camera_node
```

如果没有设置活动相机，场景不会出图。

### 背景与环境

| 方法 | 用途 |
| --- | --- |
| set_background_color(r, g, b) | 设置纯色背景 |
| set_environment_map(texture) | 设置 IBL 或 skybox 的环境贴图 |
| set_environment_intensity(value) | 调整环境光强度 |
| set_ambient_light(r, g, b) | 设置环境补光 |

### 后处理辅助方法

| 方法 | 用途 |
| --- | --- |
| set_bloom(enabled, strength=None, radius=None) | 一次性切换并设置 bloom |
| set_bloom_enabled(enabled) | 开关 bloom |
| set_bloom_strength(value) | 设置 bloom 强度 |
| set_bloom_radius(value) | 设置 bloom 半径 |
| set_ssao_enabled(enabled) | 开关 SSAO |
| set_ssao_radius(value) | 设置 SSAO 半径 |
| set_ssao_bias(value) | 设置 SSAO 偏移 |
| set_ssao_intensity(value) | 设置 SSAO 强度 |
| set_tone_mapping_mode(mode) | 切换 tone mapper |
| set_tone_mapping(mode, exposure=None, gamma=None) | 同时设置 tone mapper 与曝光/伽马 |

支持的色调映射字符串：

- "linear"
- "neutral"
- "reinhard"
- "cineon"
- "aces"
- "agx"
- "agx_punchy"

### 动画辅助方法

| 方法 | 用途 |
| --- | --- |
| play_animation(node, name) | 播放指定名字的动画片段 |
| play_if_any_animation(node) | 播放第一个可用动画 |
| play_any_animation(node) | play_if_any_animation 的别名 |
| list_animations(node) | 返回动画片段名字列表 |
| get_animation_mixer(node) | 返回 AnimationMixer 或 None |

---

## Object3D

Object3D 是场景节点句柄，包含变换助手和可选的类型化组件代理。

### 变换属性

| 属性 | 单位 |
| --- | --- |
| position | xyz 坐标 |
| rotation | 弧度 |
| rotation_euler | 角度 |
| scale | xyz 缩放 |

### 通用属性

| 属性 | 含义 |
| --- | --- |
| visible | 节点可见性 |
| cast_shadows | 网格投射阴影开关 |
| receive_shadows | 网格接收阴影开关 |
| name | 可选节点名 |

### 变换辅助方法

- set_uniform_scale(s)
- rotate_x(angle)
- rotate_y(angle)
- rotate_z(angle)
- rotate_world_x(angle)
- rotate_world_y(angle)
- rotate_world_z(angle)
- look_at(target)

### 组件代理

| 属性 | 返回值 |
| --- | --- |
| light | DirectionalLightComponent | PointLightComponent | SpotLightComponent | None |
| camera | PerspectiveCameraComponent | OrthographicCameraComponent | None |
| mesh | MeshComponent | None |

---

## 几何体、材质、相机与灯光

### 几何体类型

- BoxGeometry
- SphereGeometry
- PlaneGeometry
- Geometry，用于自定义顶点和索引数据

### 材质类型

- UnlitMaterial
- PhongMaterial
- PhysicalMaterial

对于大多数 PBR 场景，优先使用 PhysicalMaterial。颜色既可以传 #ff7a33 这样的字符串，也可以传浮点序列。

### 相机类型

- PerspectiveCamera
- OrthographicCamera
- AntiAliasing

### 灯光类型

- DirectionalLight
- PointLight
- SpotLight

运行时创建节点后，可以通过 node.camera 与 node.light 继续调整对应组件。

---

## TextureHandle 与动态纹理

TextureHandle 是纹理加载与创建 API 返回的句柄。

动态纹理工作流：

```python
texture = ctx.create_dynamic_texture(
    "dynamic-rgba",
    width,
    height,
    initial_bytes,
    color_space="srgb",
)

texture.update_data(next_frame_bytes)
```

可接受的输入缓冲包括：

- bytes
- bytearray
- memoryview
- NumPy 等提供的 C 连续 uint8 缓冲

update_data(...) 只适用于通过 create_dynamic_texture(...) 创建的纹理。

---

## OrbitControls 与 Input

### OrbitControls

```python
orbit = myth.OrbitControls(position=[0.0, 2.0, 5.0], target=[0.0, 0.0, 0.0])
orbit.update(camera_node, frame.dt)
```

常用成员：

- enable_damping
- damping_factor
- rotate_speed
- zoom_speed
- pan_speed
- min_distance
- max_distance
- set_target(...)
- fit(node)

### Input

Engine.input 和 Renderer.input 暴露输入状态代理。在外部窗口模式下，需要用 Renderer 的 inject_* 方法把事件送进去。

---

## ReadbackStream

ReadbackStream 是高吞吐离屏回读的专家接口。

创建方式：

```python
stream = renderer.create_readback_stream(buffer_count=3, max_stash_size=64)
```

核心方法：

| 方法 | 用途 |
| --- | --- |
| try_submit(renderer) | 非阻塞提交一帧回读 |
| submit_blocking(renderer) | 带背压的阻塞提交 |
| try_recv() | 返回包含新分配 bytes 的字典 |
| try_recv_into(buffer) | 复用调用方提供的 bytearray |
| flush(renderer) | 等待并回收所有飞行中的帧 |

只读属性：

- buffer_count
- frames_submitted
- dimensions
- frame_byte_size

Renderer 还提供基于内部流的简单录制方法：

- start_recording(...)
- render_and_record(...)
- try_pull_frame()
- flush_recording()

---

## GaussianCloud

GaussianCloud 表示一个已加载但尚未挂到场景里的 splat 数据集。

```python
cloud = ctx.load_gaussian_npz("point_cloud.npz")
print(cloud.count)
cloud.color_space = "linear"
```

属性：

| 属性 | 含义 |
| --- | --- |
| count | splat 数量 |
| num_points | count 的兼容别名 |
| sh_degree | 球谐系数阶数 |
| aabb_min | 包围盒最小角 |
| aabb_max | 包围盒最大角 |
| center | 包围盒中心 |
| scene_extent | 由包围盒估算出的场景尺度 |
| color_space | "srgb" 或 "linear" |

将它挂入场景时使用 scene.add_gaussian_cloud(name, cloud)。

---

## 示例索引

下列 Python 示例最能体现当前公开 API：

| 示例 | 覆盖内容 |
| --- | --- |
| ../examples/demo.py | 基础场景与轨道控制 |
| ../examples/video_texture.py | 动态纹理更新 |
| ../examples/gaussian_splatting.py | GaussianCloud 与高保真渲染路径 |
| ../examples/headless_stream_test.py | ReadbackStream 工作流 |
| ../examples/glfw_demo.py | 原生窗口嵌入 |
| ../examples/pyside_demo.py | Qt 嵌入 |