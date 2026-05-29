# Myth Engine Python User Guide

This guide follows the current Python binding surface exposed by myth and the examples under bindings/python/examples.

Use this document together with [API.md](API.md) when you want concrete signatures and object names.

---

## 1. Runtime Model

The current Python API is easiest to understand as five layers:

1. App: built-in window and event loop.
2. Renderer: external-window or headless runtime.
3. Engine: callback-time proxy for scene creation and asset loading.
4. Scene: active-scene proxy for cameras, lights, environment, and animation.
5. Object3D: scene node handle with transform helpers and component proxies.

Two practical rules matter immediately:

- App and Renderer default to the basic render path if you omit render_path.
- Advanced effects such as bloom, tone mapping, SSAO, SSGI, SSR, and Gaussian splatting should use RenderPath.HIGH_FIDELITY explicitly.

---

## 2. Installation

### From PyPI

```bash
pip install myth-py
```

### From source

```bash
git clone https://github.com/panxinmiao/myth.git
cd myth/bindings/python
pip install maturin
maturin develop --release
```

The bindings currently target Python 3.10+.

---

## 3. Quick Start with App

App is the shortest path to a running scene.

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

The important parts are:

- create the scene inside @app.init
- assign scene.active_camera before rendering
- use frame.dt for motion and controller updates
- use RenderPath.HIGH_FIDELITY when you want post-processing

---

## 4. Building Scenes

### Meshes

Use Scene.add_mesh(...) with a geometry object and a material object:

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

Built-in geometry classes:

- BoxGeometry
- SphereGeometry
- PlaneGeometry
- Geometry for custom vertex/index buffers

Built-in material classes:

- UnlitMaterial
- PhongMaterial
- PhysicalMaterial

### Cameras and lights

All cameras and lights are attached to Object3D nodes.

```python
camera = scene.add_camera(myth.PerspectiveCamera(fov=45.0, near=0.1))
camera.position = [0.0, 1.5, 4.0]
camera.look_at([0.0, 0.0, 0.0])
scene.active_camera = camera

sun = scene.add_light(myth.DirectionalLight(intensity=4.0))
sun.position = [4.0, 6.0, 2.0]
sun.look_at([0.0, 0.0, 0.0])
```

If scene.active_camera is never assigned, the scene will update but nothing will be drawn.

### Background, environment, and post-processing

Current convenience methods on Scene include:

- set_background_color(r, g, b)
- set_environment_map(texture)
- set_environment_intensity(value)
- set_ambient_light(r, g, b)
- set_bloom(...)
- set_tone_mapping(...)
- set_ssao_*...

Typical high-fidelity setup:

```python
scene.set_background_color(0.04, 0.05, 0.08)
scene.set_bloom(True, strength=0.05, radius=0.004)
scene.set_tone_mapping("agx", exposure=1.0)
scene.set_ssao_enabled(True)
```

### Transform conventions

Object3D exposes both radians and degrees, but they are not interchangeable:

- node.rotation uses radians.
- node.rotation_euler uses degrees.

Common helpers:

- set_uniform_scale(...)
- rotate_x(...), rotate_y(...), rotate_z(...)
- rotate_world_x(...), rotate_world_y(...), rotate_world_z(...)
- look_at(...)

### Orbit controls

OrbitControls follows the current scene camera node directly:

```python
orbit = myth.OrbitControls(position=[0.0, 2.0, 5.0], target=[0.0, 0.0, 0.0])

@app.update
def on_update(ctx: myth.Engine, frame: myth.FrameState) -> None:
    orbit.update(camera_node, frame.dt)
```

The controller works with the camera Object3D, not the camera component proxy.

### Component proxies

Nodes expose live typed component proxies:

```python
if camera.camera:
    camera.camera.fov = 55.0

if sun.light:
    sun.light.intensity = 6.0

if cube_node.mesh:
    cube_node.mesh.cast_shadows = True
```

This is the preferred way to inspect or tune an attached component after node creation.

---

## 5. Loading Assets

### Textures and HDR environments

```python
albedo = ctx.load_texture("assets/albedo.png", color_space="srgb", generate_mipmaps=True)
normal = ctx.load_texture("assets/normal.png", color_space="linear", generate_mipmaps=True)
hdr = ctx.load_hdr_texture("assets/studio.hdr")

scene.set_environment_map(hdr)
scene.set_environment_intensity(1.0)
```

Use srgb for color textures and linear for data textures such as normal maps.

### glTF and animation

```python
root = ctx.load_gltf("assets/helmet.glb")
scene.play_if_any_animation(root)
```

Animation helpers on Scene:

- play_animation(node, name)
- play_if_any_animation(node)
- list_animations(node)
- get_animation_mixer(node)

Reference examples:

- [../examples/gltf_viewer.py](../examples/gltf_viewer.py)
- [../examples/sponza.py](../examples/sponza.py)
- [../examples/morph.py](../examples/morph.py)

### Dynamic textures

The current bindings expose a direct dynamic-texture workflow for video frames, CPU effects, and GUI surfaces:

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

Accepted buffers include:

- bytes
- bytearray
- memoryview
- C-contiguous uint8 arrays such as NumPy RGBA buffers

Reference example:

- [../examples/video_texture.py](../examples/video_texture.py)

### 3D Gaussian splatting

The bindings now expose Gaussian cloud loading and scene attachment directly:

```python
cloud = ctx.load_gaussian_npz("assets/point_cloud.npz")
cloud.color_space = "linear"

node = scene.add_gaussian_cloud("gaussian_cloud", cloud)
node.rotation_euler = [90.0, 0.0, 0.0]
```

Use RenderPath.HIGH_FIDELITY for these scenes.

Reference example:

- [../examples/gaussian_splatting.py](../examples/gaussian_splatting.py)

---

## 6. Renderer Mode and External Windows

Use Renderer when another toolkit owns the window.

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

Important responsibilities in this mode:

- forward resize events with renderer.resize(width, height)
- inject keyboard and mouse input with inject_* methods
- drive the render loop yourself via update(), render(), or frame()

Reference examples:

- [../examples/glfw_demo.py](../examples/glfw_demo.py)
- [../examples/pyside_demo.py](../examples/pyside_demo.py)
- [../examples/rendercanvas_demo.py](../examples/rendercanvas_demo.py)

---

## 7. Headless Rendering and Readback

### Simple headless rendering

```python
renderer = myth.Renderer(render_path=myth.RenderPath.HIGH_FIDELITY)
renderer.init_headless(1280, 720)

scene = renderer.create_scene()
# build scene

renderer.frame(1.0 / 60.0)
pixels = renderer.readback_pixels()
renderer.dispose()
```

This is the simplest path for exporters, tests, and one-shot renders.

Reference examples:

- [../examples/headless_simple_test.py](../examples/headless_simple_test.py)
- [../examples/headless_readback_test.py](../examples/headless_readback_test.py)

### Streaming readback

For continuous capture, use ReadbackStream:

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

Reference example:

- [../examples/headless_stream_test.py](../examples/headless_stream_test.py)

---

## 8. Input and Frame Logic

FrameState exposes the current timing information:

- frame.delta_time and frame.dt
- frame.elapsed and frame.time
- frame.frame_count

Engine.input and Renderer.input expose the input proxy. In external-window mode you populate it with the inject_* methods on Renderer.

Typical pattern:

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

## 9. Example Roadmap

These examples match the current public binding surface best:

| Example | Coverage |
| --- | --- |
| [../examples/demo.py](../examples/demo.py) | Core scene setup, mesh creation, orbit controls |
| [../examples/earth.py](../examples/earth.py) | Textures and layered scene composition |
| [../examples/bloom_demo.py](../examples/bloom_demo.py) | High-fidelity post-processing |
| [../examples/video_texture.py](../examples/video_texture.py) | Dynamic texture updates |
| [../examples/gaussian_splatting.py](../examples/gaussian_splatting.py) | Gaussian splatting |
| [../examples/shadows.py](../examples/shadows.py) | Light setup and shadow toggles |
| [../examples/gltf_viewer.py](../examples/gltf_viewer.py) | General GLB viewer |
| [../examples/glfw_demo.py](../examples/glfw_demo.py) | External window integration |
| [../examples/pyside_demo.py](../examples/pyside_demo.py) | Qt embedding |
| [../examples/rendercanvas_demo.py](../examples/rendercanvas_demo.py) | rendercanvas embedding |
| [../examples/headless_simple_test.py](../examples/headless_simple_test.py) | Minimal offscreen render |
| [../examples/headless_stream_test.py](../examples/headless_stream_test.py) | Streaming readback |

---

## 10. Common Pitfalls

- No active camera means the scene updates but nothing is rendered.
- rotation is radians while rotation_euler is degrees.
- App and Renderer default to the basic render path if render_path is omitted.
- TextureHandle.update_data(...) only works for textures created through create_dynamic_texture(...).
- In external-window mode, forgetting renderer.resize(...) or input injection usually looks like a camera or viewport bug.
- For headless streaming loops, call renderer.poll_device() so completed frames can become available.