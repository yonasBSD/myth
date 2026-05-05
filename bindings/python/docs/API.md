# Myth Engine Python API Reference

This reference describes the current public Python binding surface implemented under bindings/python/src and surfaced to users through the myth module and myth/__init__.pyi.

Use this document together with [UserGuide.md](UserGuide.md) when you want practical examples.

---

## Module Overview

| Entry | Purpose |
| --- | --- |
| `myth.App` | Built-in window + event loop |
| `myth.Renderer` | External-window or headless renderer |
| `myth.Engine` | Callback-time engine proxy |
| `myth.Scene` | Active-scene proxy for scene creation and settings |
| `myth.Object3D` | Scene node handle with transform helpers |
| `myth.TextureHandle` | Opaque texture handle, including dynamic updates |
| `myth.ReadbackStream` | High-throughput headless readback |
| `myth.GaussianCloud` | Loaded 3D Gaussian splat asset |
| `myth.OrbitControls` | Camera orbit helper |

Important conventions in the current bindings:

- `rotation` uses radians.
- `rotation_euler` uses degrees.
- `FrameState` exposes both `delta_time` and the alias `dt`, plus `elapsed` and the alias `time`.
- `App` and `Renderer` default to the basic render path unless you set `render_path` explicitly.

---

## RenderPath

```python
myth.RenderPath.BASIC
myth.RenderPath.HIGH_FIDELITY
```

| Value | Meaning |
| --- | --- |
| `RenderPath.BASIC` | Forward LDR path |
| `RenderPath.HIGH_FIDELITY` | HDR + post-processing path |

The bindings also accept legacy strings such as `"basic"`, `"hdr"`, and `"high_fidelity"`, but the enum is preferred in new code.

Use `HIGH_FIDELITY` when you need bloom, tone mapping, SSAO, or Gaussian splatting.

---

## ClusteredShadingMode

```python
myth.ClusteredShadingMode.force_off()
myth.ClusteredShadingMode.force_on()
myth.ClusteredShadingMode.auto(threshold=16)
```

| Mode | Meaning |
| --- | --- |
| `force_off()` | Always use the classic forward light loop |
| `force_on()` | Always run clustered-lighting compute passes |
| `auto(threshold=N)` | Switch to clustered shading once the scene light count reaches `N` |

---

## App

`App` is the highest-level entry point.

```python
app = myth.App(
    title="Myth Engine",
    render_path=myth.RenderPath.HIGH_FIDELITY,
    vsync=True,
    clustered_shading=myth.ClusteredShadingMode.auto(20),
    clear_color=[0.1, 0.1, 0.1, 1.0],
)
```

Core members:

| Member | Type | Notes |
| --- | --- | --- |
| `title` | `str` | Window title |
| `render_path` | `str | RenderPath` | Defaults to the basic path when omitted |
| `clustered_shading` | `str | ClusteredShadingMode` | Controls classic-vs-clustered forward lighting routing |
| `vsync` | `bool` | Presentation mode toggle |
| `clear_color` | `ColorInput` | Wrapper-side property; use `scene.set_background_color(...)` for visible scene background |

Decorator workflow:

```python
@app.init
def on_init(ctx: myth.Engine) -> None:
    ...

@app.update
def on_update(ctx: myth.Engine, frame: myth.FrameState) -> None:
    ...

app.run()
```

The engine context is only valid during `@app.init` and `@app.update` callbacks.

---

## Renderer

`Renderer` exposes the engine without owning the window. Use it for GLFW, Qt, rendercanvas, or pure headless rendering.

```python
renderer = myth.Renderer(
    render_path=myth.RenderPath.HIGH_FIDELITY,
    vsync=True,
    clustered_shading=myth.ClusteredShadingMode.force_on(),
)
```

Initialization methods:

| Method | Purpose |
| --- | --- |
| `init_with_handle(window_handle, width, height)` | Bind to a native platform window |
| `init_headless(width, height, format=None)` | Start an offscreen renderer |
| `dispose()` | Release GPU resources |

Frame-control methods:

| Method | Purpose |
| --- | --- |
| `update(dt=None)` | Advance engine time and scene logic |
| `render()` | Draw one frame |
| `frame(dt=None)` | `update()` + `render()` |
| `resize(width, height)` | Notify the renderer about a new size |

Scene and asset methods mirrored from `Engine`:

- `create_scene()`
- `active_scene()`
- `load_texture(...)`
- `create_dynamic_texture(...)`
- `load_hdr_texture(...)`
- `load_gltf(...)`

Input injection methods for external windows:

- `inject_key_down(key)`
- `inject_key_up(key)`
- `inject_mouse_move(x, y)`
- `inject_mouse_down(button)`
- `inject_mouse_up(button)`
- `inject_scroll(dx, dy)`

Read-only runtime properties:

- `time`
- `frame_count`
- `input`

---

## Engine

`Engine` is the proxy object passed into App callbacks.

Read-only properties:

| Property | Meaning |
| --- | --- |
| `time` | Elapsed time in seconds |
| `frame_count` | Number of frames processed |
| `input` | Input proxy |

Primary methods:

| Method | Purpose |
| --- | --- |
| `create_scene()` | Create and activate a scene |
| `active_scene()` | Get the current scene proxy |
| `load_texture(path, color_space="srgb", generate_mipmaps=True)` | Load an image texture |
| `create_dynamic_texture(name, width, height, data, color_space="srgb", generate_mipmaps=False)` | Create a mutable RGBA texture |
| `load_hdr_texture(path)` | Load an HDR environment texture |
| `load_gltf(path)` | Load and instantiate a glTF/GLB asset into the active scene |
| `load_gaussian_ply(path)` | Load a Gaussian splat cloud from PLY |
| `load_gaussian_npz(path)` | Load a Gaussian splat cloud from NPZ |
| `set_title(title)` | Update the built-in window title when App mode is active |

`Renderer` exposes the same scene-creation and asset-loading surface once it is initialized.

---

## FrameState

`FrameState` is passed to `@app.update`.

| Property | Alias | Meaning |
| --- | --- | --- |
| `delta_time` | `dt` | Seconds since the previous frame |
| `elapsed` | `time` | Total elapsed seconds |
| `frame_count` | none | Total frame index |

---

## Scene

`Scene` is a proxy for the currently active scene.

### Core node creation

| Method | Returns |
| --- | --- |
| `add_mesh(geometry, material)` | `Object3D` |
| `add_camera(camera)` | `Object3D` |
| `add_light(light)` | `Object3D` |
| `add_gaussian_cloud(name, cloud)` | `Object3D` |
| `attach(child, parent)` | `None` |
| `find_node_by_name(name)` | `Object3D | None` |

### Active camera

```python
scene.active_camera = camera_node
```

If no active camera is set, nothing is rendered.

### Background and environment

| Method | Purpose |
| --- | --- |
| `set_background_color(r, g, b)` | Set a solid background color |
| `set_environment_map(texture)` | Set the IBL/skybox source texture |
| `set_environment_intensity(value)` | Control environment light strength |
| `set_ambient_light(r, g, b)` | Set ambient contribution |

### Post-processing helpers

| Method | Purpose |
| --- | --- |
| `set_bloom(enabled, strength=None, radius=None)` | Convenience bloom toggle and tuning |
| `set_bloom_enabled(enabled)` | Toggle bloom |
| `set_bloom_strength(value)` | Tune bloom strength |
| `set_bloom_radius(value)` | Tune bloom radius |
| `set_ssao_enabled(enabled)` | Toggle SSAO |
| `set_ssao_radius(value)` | Tune SSAO radius |
| `set_ssao_bias(value)` | Tune SSAO bias |
| `set_ssao_intensity(value)` | Tune SSAO intensity |
| `set_tone_mapping_mode(mode)` | Change tone-mapper |
| `set_tone_mapping(mode, exposure=None, gamma=None)` | Tone-mapper + exposure/gamma |

Supported tone-mapping strings:

- `"linear"`
- `"neutral"`
- `"reinhard"`
- `"cineon"`
- `"aces"`
- `"agx"`
- `"agx_punchy"`

### Animation helpers

| Method | Purpose |
| --- | --- |
| `play_animation(node, name)` | Play a named animation clip |
| `play_if_any_animation(node)` | Play the first available clip |
| `play_any_animation(node)` | Alias for `play_if_any_animation` |
| `list_animations(node)` | Return available clip names |
| `get_animation_mixer(node)` | Return `AnimationMixer` or `None` |

---

## Object3D

`Object3D` is a scene node handle with transform helpers and optional typed component proxies.

### Transform properties

| Property | Units |
| --- | --- |
| `position` | xyz coordinates |
| `rotation` | radians |
| `rotation_euler` | degrees |
| `scale` | xyz scale |

### General properties

| Property | Meaning |
| --- | --- |
| `visible` | Node visibility |
| `cast_shadows` | Mesh shadow-casting toggle |
| `receive_shadows` | Mesh shadow-receive toggle |
| `name` | Optional node name |

### Transform helpers

- `set_uniform_scale(s)`
- `rotate_x(angle)`
- `rotate_y(angle)`
- `rotate_z(angle)`
- `rotate_world_x(angle)`
- `rotate_world_y(angle)`
- `rotate_world_z(angle)`
- `look_at(target)`

### Component proxies

| Property | Returns |
| --- | --- |
| `light` | `DirectionalLightComponent | PointLightComponent | SpotLightComponent | None` |
| `camera` | `PerspectiveCameraComponent | OrthographicCameraComponent | None` |
| `mesh` | `MeshComponent | None` |

---

## Geometry, Materials, Cameras, and Lights

### Geometry classes

- `BoxGeometry`
- `SphereGeometry`
- `PlaneGeometry`
- `Geometry` for custom vertex/index data

### Material classes

- `UnlitMaterial`
- `PhongMaterial`
- `PhysicalMaterial`

Use `PhysicalMaterial` for most PBR scenes. The bindings accept color strings such as `"#ff7a33"` as well as float sequences.

### Camera classes

- `PerspectiveCamera`
- `OrthographicCamera`
- `AntiAliasing`

### Light classes

- `DirectionalLight`
- `PointLight`
- `SpotLight`

The runtime node proxies expose their components through `node.camera` and `node.light`, so you can create a node first and tune the attached component later.

---

## TextureHandle and Dynamic Texture Updates

`TextureHandle` is the opaque reference returned by texture-loading and texture-creation APIs.

Dynamic-texture workflow:

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

Accepted input buffers include:

- `bytes`
- `bytearray`
- `memoryview`
- other C-contiguous `uint8` buffers such as NumPy arrays

`update_data(...)` only works on textures created through `create_dynamic_texture(...)`.

---

## OrbitControls and Input

### OrbitControls

```python
orbit = myth.OrbitControls(position=[0.0, 2.0, 5.0], target=[0.0, 0.0, 0.0])
orbit.update(camera_node, frame.dt)
```

Important members:

- `enable_damping`
- `damping_factor`
- `rotate_speed`
- `zoom_speed`
- `pan_speed`
- `min_distance`
- `max_distance`
- `set_target(...)`
- `fit(node)`

### Input

`Engine.input` and `Renderer.input` expose the current input proxy. In external-window mode you populate it with the `inject_*` methods on `Renderer`.

---

## ReadbackStream

`ReadbackStream` is the expert-mode API for high-throughput offscreen capture.

Creation:

```python
stream = renderer.create_readback_stream(buffer_count=3, max_stash_size=64)
```

Core methods:

| Method | Purpose |
| --- | --- |
| `try_submit(renderer)` | Non-blocking submission |
| `submit_blocking(renderer)` | Submission with back-pressure |
| `try_recv()` | Return a dict with freshly allocated bytes |
| `try_recv_into(buffer)` | Reuse a caller-supplied bytearray |
| `flush(renderer)` | Drain all in-flight frames |

Read-only properties:

- `buffer_count`
- `frames_submitted`
- `dimensions`
- `frame_byte_size`

Simple mode on `Renderer` wraps the same machinery with:

- `start_recording(...)`
- `render_and_record(...)`
- `try_pull_frame()`
- `flush_recording()`

---

## GaussianCloud

`GaussianCloud` represents a loaded splat dataset before it is attached to a scene.

```python
cloud = ctx.load_gaussian_npz("point_cloud.npz")
print(cloud.count)
cloud.color_space = "linear"
```

Properties:

| Property | Meaning |
| --- | --- |
| `count` | Number of splats |
| `num_points` | Compatibility alias for `count` |
| `sh_degree` | Spherical harmonics degree |
| `aabb_min` | Bounding box minimum corner |
| `aabb_max` | Bounding box maximum corner |
| `center` | Bounding-box center |
| `scene_extent` | Scene extent derived from the bounds |
| `color_space` | `"srgb"` or `"linear"` |

Attach the asset with `scene.add_gaussian_cloud(name, cloud)`.

---

## Example Index

Use these Python examples as the canonical API reference when in doubt:

| Example | Coverage |
| --- | --- |
| `../examples/demo.py` | Core scene and orbit workflow |
| `../examples/video_texture.py` | Dynamic texture updates |
| `../examples/gaussian_splatting.py` | Gaussian clouds and high-fidelity path |
| `../examples/headless_stream_test.py` | `ReadbackStream` workflow |
| `../examples/glfw_demo.py` | Native window embedding |
| `../examples/pyside_demo.py` | Qt embedding |