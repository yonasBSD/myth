"""
Myth Engine — Screen-Space Lighting Demo
========================================

Interactive Cornell-box-inspired showcase for Screen-Space Global Illumination
(SSGI) and Screen-Space Reflections (SSR).

Controls:
    G       - Toggle SSGI on/off
    R       - Toggle SSR on/off
    Q       - Cycle shared quality preset
    1 / 2   - Decrease / increase SSGI intensity
    3 / 4   - Decrease / increase SSR intensity
    Mouse   - Orbit camera

Usage:
    maturin develop --release
    python examples/screen_space_demo.py
"""

import myth

from __asset_utils import get_asset

HDR_ENV = get_asset("envs/royal_esplanade_2k.hdr.jpg")

app = myth.App(
    title="Screen-Space Lighting Demo",
    render_path=myth.RenderPath.HIGH_FIDELITY,
    vsync=False,
)

orbit = myth.OrbitControls(position=[2.6, 2.0, 7.8], target=[0.0, 0.6, -0.4])

cam = None

qualities = ["low", "medium", "high", "ultra"]
quality_index = 3
ssgi_enabled = True
ssr_enabled = True
ssgi_intensity = 1.35
ssr_intensity = 1.35

fps_interval = 0.5
fps_accum_time = 0.0
fps_accum_frames = 0


def spawn_box(
    scene: myth.Scene,
    width: float,
    height: float,
    depth: float,
    position: list[float],
    material: myth.PhysicalMaterial,
) -> myth.Object3D:
    node = scene.add_mesh(myth.BoxGeometry(width, height, depth), material)
    node.position = position
    return node


def apply_screen_space_settings(scene: myth.Scene) -> None:
    scene.set_ssgi(
        ssgi_enabled,
        quality=qualities[quality_index],
        intensity=ssgi_intensity,
        max_distance=8.0,
        thickness=0.16,
    )
    scene.set_ssgi_max_steps(24)
    scene.set_ssgi_atrous_passes(4)

    scene.set_ssr(
        ssr_enabled,
        quality=qualities[quality_index],
        intensity=ssr_intensity,
        max_distance=22.0,
        thickness=0.01,
        spatial_radius=1,
    )
    scene.set_ssr_max_steps(32)


@app.init
def on_init(ctx: myth.Engine) -> None:
    global cam

    scene = ctx.create_scene()
    env_tex = ctx.load_hdr_texture(HDR_ENV)
    scene.set_environment_map(env_tex)
    scene.set_environment_intensity(0.55)
    scene.set_background_color(0.012, 0.014, 0.018)
    scene.set_ambient_light(0.006, 0.006, 0.006)
    scene.set_tone_mapping("agx_punchy", exposure=1.05)

    white_wall = myth.PhysicalMaterial(color=[0.76, 0.75, 0.73], roughness=0.86, metalness=0.0)
    red_wall = myth.PhysicalMaterial(color=[0.82, 0.20, 0.16], roughness=0.92, metalness=0.0)
    cyan_wall = myth.PhysicalMaterial(color=[0.12, 0.54, 0.90], roughness=0.90, metalness=0.0)
    graphite_floor = myth.PhysicalMaterial(color=[0.10, 0.11, 0.13], roughness=0.04, metalness=0.08)
    pedestal = myth.PhysicalMaterial(color=[0.18, 0.19, 0.22], roughness=0.44, metalness=0.32)
    chrome = myth.PhysicalMaterial(color=[0.96, 0.97, 0.99], roughness=0.05, metalness=1.0)
    copper = myth.PhysicalMaterial(color=[0.98, 0.58, 0.30], roughness=0.12, metalness=1.0)
    champagne = myth.PhysicalMaterial(color=[0.93, 0.84, 0.64], roughness=0.22, metalness=0.92)
    ink_mirror = myth.PhysicalMaterial(color=[0.05, 0.06, 0.07], roughness=0.07, metalness=0.96)
    cyan_emissive = myth.PhysicalMaterial(
        color=[0.06, 0.12, 0.16],
        roughness=0.08,
        metalness=0.0,
        emissive=[0.24, 0.95, 1.0],
        emissive_intensity=5.6,
    )
    magenta_emissive = myth.PhysicalMaterial(
        color=[0.14, 0.06, 0.11],
        roughness=0.08,
        metalness=0.0,
        emissive=[1.0, 0.34, 0.74],
        emissive_intensity=5.2,
    )
    amber_emissive = myth.PhysicalMaterial(
        color=[0.18, 0.13, 0.05],
        roughness=0.08,
        metalness=0.0,
        emissive=[1.0, 0.78, 0.28],
        emissive_intensity=5.0,
    )

    spawn_box(scene, 6.8, 0.12, 6.8, [0.0, -1.4, -0.1], white_wall)
    spawn_box(scene, 6.8, 0.12, 6.8, [0.0, 3.4, -0.1], white_wall)
    spawn_box(scene, 6.8, 4.8, 0.12, [0.0, 1.0, -3.4], white_wall)
    spawn_box(scene, 0.12, 4.8, 6.8, [-3.4, 1.0, -0.1], red_wall)
    spawn_box(scene, 0.12, 4.8, 6.8, [3.4, 1.0, -0.1], cyan_wall)

    spawn_box(scene, 6.3, 0.18, 6.1, [0.0, -1.23, 0.10], graphite_floor)

    spawn_box(scene, 1.75, 0.84, 1.75, [-2.35, -0.84, 1.45], pedestal)
    spawn_box(scene, 1.75, 0.84, 1.75, [0.0, -0.84, 0.05], pedestal)
    spawn_box(scene, 1.75, 0.84, 1.75, [2.35, -0.84, -1.35], pedestal)
    spawn_box(scene, 1.75, 0.84, 1.75, [0.0, -0.84, -2.75], pedestal)

    hero_box = spawn_box(scene, 1.22, 2.35, 1.22, [-2.35, 0.00, 1.45], copper)
    hero_box.rotation_euler = [0.0, 18.0, 0.0]

    chrome_ball = scene.add_mesh(
        myth.SphereGeometry(radius=0.82, width_segments=48, height_segments=24),
        chrome,
    )
    chrome_ball.position = [0.0, 0.08, 0.05]

    right_showpiece = scene.add_mesh(
        myth.SphereGeometry(radius=0.72, width_segments=40, height_segments=20),
        champagne,
    )
    right_showpiece.position = [2.35, -0.02, -1.35]

    obelisk = spawn_box(scene, 0.95, 2.80, 0.95, [0.0, 0.20, -2.75], ink_mirror)
    obelisk.rotation_euler = [0.0, 12.0, 0.0]

    spawn_box(scene, 0.22, 4.20, 0.14, [-2.55, 0.65, -3.22], cyan_emissive)
    spawn_box(scene, 0.22, 4.20, 0.14, [0.0, 0.65, -3.22], amber_emissive)
    spawn_box(scene, 0.22, 4.20, 0.14, [2.55, 0.65, -3.22], magenta_emissive)

    key_light = scene.add_light(
        myth.DirectionalLight(
            color=[1.0, 0.96, 0.92],
            intensity=2.8,
            cast_shadows=True,
        )
    )
    key_light.rotation_euler = [-41.0, -32.0, 0.0]

    fill_light = scene.add_light(
        myth.DirectionalLight(
            color=[0.26, 0.38, 0.62],
            intensity=0.35,
            cast_shadows=False,
        )
    )
    fill_light.rotation_euler = [-16.0, 83.0, 0.0]

    ceiling_light = scene.add_light(
        myth.PointLight(
            color=[1.0, 0.97, 0.92],
            intensity=6.0,
            range=12.0,
            cast_shadows=True,
        )
    )
    ceiling_light.position = [0.0, 2.85, 0.15]

    cyan_accent = scene.add_light(
        myth.PointLight(color=[0.24, 0.95, 1.0], intensity=3.8, range=7.5, cast_shadows=True)
    )
    cyan_accent.position = [-2.35, 1.55, -1.10]

    amber_accent = scene.add_light(
        myth.PointLight(color=[1.0, 0.78, 0.28], intensity=3.4, range=7.0, cast_shadows=False)
    )
    amber_accent.position = [0.0, 1.45, -0.40]

    magenta_accent = scene.add_light(
        myth.PointLight(color=[1.0, 0.34, 0.74], intensity=3.8, range=7.5, cast_shadows=True)
    )
    magenta_accent.position = [2.35, 1.55, -1.95]

    cam = scene.add_camera(
        myth.PerspectiveCamera(
            fov=38.0,
            near=0.1,
            anti_aliasing=myth.AntiAliasing.taa_fxaa(),
        )
    )
    cam.position = [0.0, 2.35, 9.8]
    cam.look_at([0.0, 0.85, -0.85])
    scene.active_camera = cam

    apply_screen_space_settings(scene)

    print("=== Screen-Space Lighting Demo ===")
    print("Cornell-style color bounce + showroom-scale glossy reflections")
    print("Controls:")
    print("  G       - Toggle SSGI on/off")
    print("  R       - Toggle SSR on/off")
    print("  Q       - Cycle shared quality preset")
    print("  1/2     - Decrease/increase SSGI intensity")
    print("  3/4     - Decrease/increase SSR intensity")
    print("  Mouse   - Orbit camera")


@app.update
def on_update(ctx: myth.Engine, frame: myth.FrameState) -> None:
    global quality_index, ssgi_enabled, ssr_enabled, ssgi_intensity, ssr_intensity
    global fps_accum_time, fps_accum_frames

    scene = ctx.active_scene()
    inp = ctx.input

    if inp.key_down("g"):
        ssgi_enabled = not ssgi_enabled
        scene.set_ssgi_enabled(ssgi_enabled)
        print(f"SSGI: {'ON' if ssgi_enabled else 'OFF'}")

    if inp.key_down("r"):
        ssr_enabled = not ssr_enabled
        scene.set_ssr_enabled(ssr_enabled)
        print(f"SSR: {'ON' if ssr_enabled else 'OFF'}")

    if inp.key_down("q"):
        quality_index = (quality_index + 1) % len(qualities)
        apply_screen_space_settings(scene)
        print(f"Quality: {qualities[quality_index]}")

    if inp.key_down("1"):
        ssgi_intensity = max(0.0, ssgi_intensity - 0.1)
        scene.set_ssgi_intensity(ssgi_intensity)
        print(f"SSGI intensity: {ssgi_intensity:.2f}")

    if inp.key_down("2"):
        ssgi_intensity = min(4.0, ssgi_intensity + 0.1)
        scene.set_ssgi_intensity(ssgi_intensity)
        print(f"SSGI intensity: {ssgi_intensity:.2f}")

    if inp.key_down("3"):
        ssr_intensity = max(0.0, ssr_intensity - 0.1)
        scene.set_ssr_intensity(ssr_intensity)
        print(f"SSR intensity: {ssr_intensity:.2f}")

    if inp.key_down("4"):
        ssr_intensity = min(4.0, ssr_intensity + 0.1)
        scene.set_ssr_intensity(ssr_intensity)
        print(f"SSR intensity: {ssr_intensity:.2f}")

    orbit.update(cam, frame.dt)

    fps_accum_time += frame.dt
    fps_accum_frames += 1
    if fps_accum_time >= fps_interval:
        fps = fps_accum_frames / fps_accum_time
        ctx.set_title(
            "Screen-Space Lighting Demo | "
            f"FPS: {fps:.0f} | "
            f"Quality: {qualities[quality_index]} | "
            f"SSGI: {'ON' if ssgi_enabled else 'OFF'} {ssgi_intensity:.2f} | "
            f"SSR: {'ON' if ssr_enabled else 'OFF'} {ssr_intensity:.2f}"
        )
        fps_accum_time = 0.0
        fps_accum_frames = 0


app.run()