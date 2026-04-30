# Myth Engine Python Bindings

Official Python bindings for Myth Engine, built on top of the same Rust and wgpu renderer used by the main engine.

The Python layer mirrors the current engine architecture closely:

- `App` for a built-in window and event loop
- `Renderer` for embedding Myth into an external GUI or headless pipeline
- `Engine` and `Scene` proxies for scene construction
- typed component proxies, readback helpers, dynamic textures, and Gaussian splatting support

---

## Installation

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

The bindings target Python 3.10+.

---

## Quick Start

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

Notes for the current bindings:

- `App` and `Renderer` default to the basic render path if you omit `render_path`.
- Use `RenderPath.HIGH_FIDELITY` explicitly for bloom, tone mapping, SSAO, IBL-heavy scenes, and all 3D Gaussian splatting examples.
- `OrbitControls.update(...)` expects the camera node and `frame.dt`.

---

## Two Runtime Modes

| Mode | Entry point | Best for |
| --- | --- | --- |
| App mode | `myth.App(...)` | Standalone tools, demos, and scripts |
| Renderer mode | `myth.Renderer(...)` | GLFW, PySide6, wxPython, rendercanvas, headless pipelines |

### App mode

`App` owns the window and runs the event loop. You register callbacks with `@app.init` and `@app.update`.

### Renderer mode

`Renderer` exposes the same scene-building API without owning the window. Initialize it with a native handle or in headless mode.

```python
import myth

renderer = myth.Renderer(render_path=myth.RenderPath.HIGH_FIDELITY)
renderer.init_with_handle(window_handle, width, height)

scene = renderer.create_scene()

while running:
    poll_events()
    renderer.frame(1.0 / 60.0)

renderer.dispose()
```

---

## Current Capability Highlights

### glTF loading and animation

```python
root = ctx.load_gltf("path/to/model.glb")
scene.play_if_any_animation(root)
```

### Dynamic textures

The bindings expose the current dynamic texture workflow directly:

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

`data` can be `bytes`, `bytearray`, `memoryview`, or other C-contiguous `uint8` buffers.

### Headless rendering and readback

```python
renderer = myth.Renderer(render_path=myth.RenderPath.HIGH_FIDELITY)
renderer.init_headless(1280, 720)

scene = renderer.create_scene()
# build scene

renderer.frame(1.0 / 60.0)
pixels = renderer.readback_pixels()
```

For continuous capture, use `create_readback_stream(...)`, `try_submit(...)`, and `try_recv_into(...)`.

### 3D Gaussian splatting

```python
cloud = ctx.load_gaussian_npz("path/to/point_cloud.npz")
cloud.color_space = "linear"

node = scene.add_gaussian_cloud("gaussian_cloud", cloud)
node.rotation_euler = [90, 0, 0]
```

The reference example is `examples/gaussian_splatting.py`, and it should run with `RenderPath.HIGH_FIDELITY`.

---

## Examples

The examples directory reflects the current binding surface:

| Example | Coverage |
| --- | --- |
| `examples/demo.py` | Basic scene setup, mesh creation, orbit controls |
| `examples/earth.py` | Textures and layered scene composition |
| `examples/bloom_demo.py` | High-fidelity post-processing |
| `examples/video_texture.py` | Dynamic texture updates |
| `examples/gaussian_splatting.py` | 3DGS pipeline and cloud metadata |
| `examples/shadows.py` | Light setup and shadow toggles |
| `examples/sponza.py` | Large glTF scene loading |
| `examples/gltf_viewer.py` | Generic GLB viewer |
| `examples/glfw_demo.py` | External window integration |
| `examples/pyside_demo.py` | Qt embedding |
| `examples/rendercanvas_demo.py` | rendercanvas embedding |
| `examples/headless_simple_test.py` | Minimal offscreen render |
| `examples/headless_stream_test.py` | Readback stream usage |
| `examples/headless_readback_test.py` | Direct pixel readback |

---

## Documentation

| File | Purpose |
| --- | --- |
| [docs/API.md](docs/API.md) | Python API reference |
| [docs/API_CN.md](docs/API_CN.md) | Chinese Python API reference |
| [docs/UserGuide.md](docs/UserGuide.md) | Python user guide |
| [docs/UserGuide_CN.md](docs/UserGuide_CN.md) | Chinese Python user guide |
| [myth/__init__.pyi](myth/__init__.pyi) | Authoritative type surface for editors and static analysis |
| [../../docs/API.md](../../docs/API.md) | Rust API reference |
| [../../docs/UserGuide.md](../../docs/UserGuide.md) | Rust user guide |

---

## Practical Notes

- `rotation` uses radians, while `rotation_euler` uses degrees.
- `FrameState` exposes both `delta_time` and the alias `dt`, plus `elapsed` and the alias `time`.
- `TextureHandle.update_data(...)` only works for textures created through `create_dynamic_texture(...)`.
- `Renderer.poll_device()` is part of the readback-stream workflow and should be called in headless streaming loops.