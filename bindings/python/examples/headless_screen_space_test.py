"""
Myth Engine — Headless Screen-Space Smoke Test
==============================================

Exercises the Python SSGI/SSR helpers in a deterministic offscreen render.

Usage:
    maturin develop --release
    python examples/headless_screen_space_test.py
"""

import myth

WIDTH = 128
HEIGHT = 128


def assert_not_black(pixels: bytes, label: str) -> None:
    any_color = any(
        pixels[index] > 0 or pixels[index + 1] > 0 or pixels[index + 2] > 0
        for index in range(0, len(pixels), 4)
    )
    assert any_color, f"{label}: rendered image is entirely black"


renderer = myth.Renderer(render_path=myth.RenderPath.HIGH_FIDELITY)
renderer.init_headless(WIDTH, HEIGHT)

scene = renderer.create_scene()
scene.set_background_color(0.02, 0.03, 0.05)
scene.set_tone_mapping("aces", exposure=1.0)

scene.set_ssgi(True, quality="low", intensity=1.0, max_distance=6.0, thickness=0.25)
scene.set_ssgi_max_steps(12)
scene.set_ssgi_atrous_passes(2)

scene.set_ssr(
    True,
    quality="high",
    intensity=1.0,
    max_distance=12.0,
    thickness=0.08,
    spatial_radius=1,
)
scene.set_ssr_max_steps(12)

floor = scene.add_mesh(
    myth.BoxGeometry(6.0, 0.2, 6.0),
    myth.PhysicalMaterial(color=[0.75, 0.75, 0.78], roughness=0.28, metalness=0.0),
)
floor.position = [0.0, -1.2, 0.0]

hero = scene.add_mesh(
    myth.BoxGeometry(1.2, 1.2, 1.2),
    myth.PhysicalMaterial(color=[0.85, 0.30, 0.22], roughness=0.14, metalness=0.92),
)
hero.position = [0.0, 0.0, 0.0]

accent = scene.add_mesh(
    myth.BoxGeometry(0.35, 2.5, 3.0),
    myth.PhysicalMaterial(color=[0.22, 0.42, 0.95], roughness=0.85, metalness=0.0),
)
accent.position = [-1.8, 0.0, -0.7]

sun = scene.add_light(myth.DirectionalLight(color=[1.0, 1.0, 1.0], intensity=4.0))
sun.position = [3.0, 5.0, 3.0]

camera = scene.add_camera(myth.PerspectiveCamera(fov=45.0, near=0.1))
camera.position = [0.0, 1.4, 4.5]
camera.look_at([0.0, -0.2, 0.0])
scene.active_camera = camera

for _ in range(3):
    hero.rotate_y(0.2)
    renderer.frame(1.0 / 60.0)

pixels = renderer.readback_pixels()
assert len(pixels) == WIDTH * HEIGHT * 4
assert_not_black(pixels, "headless_screen_space_test")

print("Screen-space headless smoke test passed.")
renderer.dispose()