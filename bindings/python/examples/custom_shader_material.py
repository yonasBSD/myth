"""
Custom Shader Material Demo
===========================

Demonstrates the Python `ShaderMaterial` binding using the engine's
standard geometry-material path (`shader_mode="body"`).

Controls:
    1 / 2   - Decrease / increase displacement
    Space   - Toggle transparency boost
    Mouse   - Orbit camera

Usage:
    python examples/custom_shader_material.py
"""

import math
import myth


HOLOGRAM_SHADER = r"""
fn saturate(value: f32) -> f32 {
    return clamp(value, 0.0, 1.0);
}

@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;

    var local_position = vec3<f32>(in.position.xyz);
    var local_normal = vec3<f32>(0.0, 1.0, 0.0);

    $$ if HAS_NORMAL is defined
    local_normal = normalize(in.normal.xyz);
    $$ endif

    let ring_density = u_material.params0.x;
    let scan_density = u_material.params0.y;
    let pulse_speed = u_material.params0.z;
    let displacement = u_material.params1.y;
    let time = u_render_state.time * pulse_speed;
    let wave = sin(local_position.y * scan_density - time * 3.0);
    let ripple = sin(length(local_position.xz) * ring_density - time * 4.5);

    local_position += local_normal * (wave * 0.7 + ripple * 0.3) * displacement;

    let world_pos = u_model.world_matrix * vec4<f32>(local_position, 1.0);
    out.position = u_render_state.view_projection * world_pos;
    out.world_position = world_pos.xyz / world_pos.w;

    $$ if HAS_NORMAL is defined
    out.geometry_normal = local_normal;
    out.normal = normalize(u_model.normal_matrix * local_normal);
    $$ endif

    $$ if HAS_UV is defined
    out.uv = in.uv;
    $$ endif

    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> FragmentOutput {
    var normal = vec3<f32>(0.0, 1.0, 0.0);

    $$ if HAS_NORMAL is defined
    normal = normalize(in.normal);
    $$ endif

    let fresnel_power = u_material.params0.w;
    let edge_intensity = u_material.params1.x;
    let time = u_render_state.time * u_material.params0.z;
    let view = normalize(u_render_state.camera_position - in.world_position);
    let fresnel = pow(1.0 - saturate(dot(normal, view)), fresnel_power);
    let scan = 0.5 + 0.5 * sin(in.world_position.y * u_material.params0.y - time * 6.0);
    let ring = 0.5 + 0.5 * sin(length(in.world_position.xz) * u_material.params0.x - time * 4.0);

    let base = u_material.base_color.rgb * (0.18 + ring * 0.34);
    let accent = u_material.accent_color.rgb * scan * 0.60;
    let edge = u_material.edge_color.rgb * fresnel * edge_intensity;
    let emissive = u_material.emissive_color.rgb * (0.30 + scan * 0.25);

    let alpha = saturate(
        u_material.opacity * (0.18 + ring * 0.16 + scan * 0.24 + fresnel * 0.72)
    );

    if (alpha < u_material.alpha_test) {
        discard;
    }

    return pack_fragment_output(vec4<f32>(base + accent + edge + emissive, alpha));
}
"""


app = myth.App(
    title="Custom Shader Material",
    render_path=myth.RenderPath.HIGH_FIDELITY,
    vsync=False,
)

orbit = myth.OrbitControls(position=[0.0, 2.4, 7.8], target=[0.0, 1.6, 0.0])
camera_node = None
core_node = None
satellite_node = None
core_material = None
satellite_material = None

fps_accum_time = 0.0
fps_accum_frames = 0


def make_hologram_material(base_color, accent_color, edge_color):
    material = myth.ShaderMaterial(
        "python/custom_hologram/body",
        HOLOGRAM_SHADER,
        shader_mode="body",
        base_color=base_color,
        opacity=0.90,
        side="double",
        alpha_mode="blend",
        depth_write=False,
    )
    material.accent_color = accent_color
    material.edge_color = edge_color
    material.emissive_color = [0.04, 0.20, 0.40, 0.0]
    material.params0 = [10.0, 14.0, 2.2, 4.0]
    material.params1 = [2.2, 0.12, 0.0, 0.0]
    return material


@app.init
def on_init(ctx: myth.Engine):
    global camera_node, core_node, satellite_node, core_material, satellite_material

    scene = ctx.create_scene()
    scene.set_background_color(0.02, 0.03, 0.05)
    scene.set_tone_mapping("aces", exposure=1.0)
    scene.set_bloom(True, strength=0.03, radius=0.005)
    scene.set_ambient_light(0.04, 0.05, 0.08)

    floor = scene.add_mesh(
        myth.PlaneGeometry(width=18.0, height=18.0),
        myth.PhysicalMaterial(color="#101722", roughness=0.94, metalness=0.0),
    )
    floor.rotation_euler = [-90.0, 0.0, 0.0]
    floor.position = [0.0, 0.0, 0.0]

    key = scene.add_light(myth.DirectionalLight(color=[0.92, 0.96, 1.0], intensity=3.4))
    key.position = [5.0, 8.0, 4.0]
    key.look_at([0.0, 1.2, 0.0])

    fill = scene.add_light(myth.DirectionalLight(color=[0.30, 0.50, 1.0], intensity=1.1))
    fill.position = [-4.0, 5.0, -6.0]
    fill.look_at([0.0, 1.5, 0.0])

    core_material = make_hologram_material(
        [0.08, 0.78, 1.15, 1.0],
        [0.12, 0.56, 1.28, 1.0],
        [0.88, 0.98, 1.35, 1.0],
    )
    satellite_material = make_hologram_material(
        [1.0, 0.16, 0.62, 1.0],
        [0.88, 0.12, 1.10, 1.0],
        [1.26, 0.70, 1.18, 1.0],
    )
    satellite_material.params0 = [8.0, 11.0, 2.8, 3.6]
    satellite_material.params1 = [1.9, 0.08, 0.0, 0.0]

    core_node = scene.add_mesh(
        myth.SphereGeometry(radius=1.45, width_segments=64, height_segments=32),
        core_material,
    )
    core_node.position = [0.0, 1.55, 0.0]

    satellite_node = scene.add_mesh(
        myth.BoxGeometry(0.85, 2.4, 0.85),
        satellite_material,
    )
    satellite_node.position = [3.0, 1.8, 0.0]

    camera_node = scene.add_camera(myth.PerspectiveCamera(fov=45.0, near=0.1))
    camera_node.position = [0.0, 2.4, 7.8]
    camera_node.look_at([0.0, 1.5, 0.0])
    scene.active_camera = camera_node

    print("=== Custom Shader Material Demo ===")
    print("Controls:")
    print("  1 / 2   - Decrease / increase displacement")
    print("  Space   - Toggle transparency boost")
    print("  Mouse   - Orbit camera")


@app.update
def on_update(ctx: myth.Engine, frame: myth.FrameState):
    global fps_accum_time, fps_accum_frames

    scene = ctx.active_scene()
    inp = ctx.input
    time = ctx.time

    if inp.key_down("1"):
        params = list(core_material.params1)
        params[1] = max(0.02, params[1] - 0.01)
        core_material.params1 = params
        print(f"Core displacement: {params[1]:.2f}")

    if inp.key_down("2"):
        params = list(core_material.params1)
        params[1] = min(0.30, params[1] + 0.01)
        core_material.params1 = params
        print(f"Core displacement: {params[1]:.2f}")

    if inp.key_down("Space"):
        core_material.opacity = 0.98 if core_material.opacity < 0.95 else 0.82
        satellite_material.opacity = 0.92 if satellite_material.opacity < 0.90 else 0.74

    orbit.update(camera_node, frame.dt)

    core_node.rotate_y(frame.dt * 0.75)
    satellite_node.position = [
        math.cos(time * 0.9) * 3.1,
        1.8 + math.sin(time * 1.7) * 0.45,
        math.sin(time * 0.9) * 3.1,
    ]
    satellite_node.look_at([0.0, 1.5, 0.0])
    satellite_node.rotate_x(frame.dt * 0.6)

    fps_accum_time += frame.dt
    fps_accum_frames += 1
    if fps_accum_time >= 0.5:
        fps = fps_accum_frames / fps_accum_time
        ctx.set_title(
            f"Custom Shader Material | FPS: {fps:.0f} | Displacement: {core_material.params1[1]:.2f}"
        )
        fps_accum_time = 0.0
        fps_accum_frames = 0


app.run()