"""
Custom Post FX Demo
===================

Demonstrates the Python post-process extension path:

1. Register a named WGSL shader template.
2. Create a reusable `FullscreenPostPass`.
3. Attach it to the built-in App render loop.

Controls:
    Space   - Toggle the custom post effect
    Mouse   - Orbit camera

Usage:
    python examples/custom_post_fx.py
"""

import math
import myth


POST_SHADER_NAME = "python/custom_post_fx/split_scan"

POST_SHADER = r"""
struct VsOut {
    @builtin(position) position: vec4<f32>,
    @location(0) uv: vec2<f32>,
};

@group(0) @binding(0) var t_input: texture_2d<f32>;
@group(0) @binding(1) var s_input: sampler;

@vertex
fn vs_main(@builtin(vertex_index) vertex_index: u32) -> VsOut {
    var out: VsOut;
    let pos = array<vec2<f32>, 3>(
        vec2<f32>(-1.0, -3.0),
        vec2<f32>(-1.0,  1.0),
        vec2<f32>( 3.0,  1.0),
    );
    let uv = array<vec2<f32>, 3>(
        vec2<f32>(0.0, 2.0),
        vec2<f32>(0.0, 0.0),
        vec2<f32>(2.0, 0.0),
    );
    out.position = vec4<f32>(pos[vertex_index], 0.0, 1.0);
    out.uv = uv[vertex_index];
    return out;
}

fn luminance(color: vec3<f32>) -> f32 {
    return dot(color, vec3<f32>(0.2126, 0.7152, 0.0722));
}

@fragment
fn fs_main(in: VsOut) -> @location(0) vec4<f32> {
    let centered = in.uv * 2.0 - vec2<f32>(1.0, 1.0);
    let radius = length(centered);
    let dir = normalize(centered + vec2<f32>(1e-4, 0.0));
    let aberr = 0.001 + radius * 0.008;

    let center = textureSample(t_input, s_input, in.uv).rgb;
    let right = textureSample(t_input, s_input, in.uv + dir * aberr).rgb;
    let left = textureSample(t_input, s_input, in.uv - dir * aberr).rgb;
    var color = vec3<f32>(right.r, center.g, left.b);

    let lum = luminance(center);
    let edge_h = abs(lum - luminance(textureSample(t_input, s_input, in.uv + vec2<f32>(0.003, 0.0)).rgb));
    let edge_v = abs(lum - luminance(textureSample(t_input, s_input, in.uv + vec2<f32>(0.0, 0.003)).rgb));
    let edge = clamp((edge_h + edge_v) * 2.6, 0.0, 1.0);

    let scanline = 0.93 + 0.07 * sin(in.uv.y * 900.0);
    let vignette = 1.0 - smoothstep(0.38, 1.10, radius);
    let glow = center * vec3<f32>(0.20, 0.32, 0.55) * edge * 2.2;

    color = color * scanline * (0.72 + vignette * 0.55) + glow;
    return vec4<f32>(color, 1.0);
}
"""


app = myth.App(
    title="Custom Post FX",
    render_path=myth.RenderPath.HIGH_FIDELITY,
    vsync=False,
)

orbit = myth.OrbitControls(position=[0.0, 2.8, 9.5], target=[0.0, 1.6, 0.0])
camera_node = None
orb_nodes = []
ring_light = None
post_pass = myth.FullscreenPostPass("Python Retro Split", POST_SHADER_NAME)

fps_accum_time = 0.0
fps_accum_frames = 0


@app.init
def on_init(ctx: myth.Engine):
    global camera_node, ring_light

    ctx.register_shader_template(POST_SHADER_NAME, POST_SHADER)
    ctx.add_fullscreen_post_pass(post_pass)

    scene = ctx.create_scene()
    scene.set_background_color(0.02, 0.03, 0.05)
    scene.set_tone_mapping("aces", exposure=1.0)
    scene.set_bloom(True, strength=0.08, radius=0.006)
    scene.set_ambient_light(0.01, 0.01, 0.02)

    floor = scene.add_mesh(
        myth.BoxGeometry(18.0, 0.25, 18.0),
        myth.PhysicalMaterial(color="#10151c", roughness=0.96, metalness=0.0),
    )
    floor.position = [0.0, -0.1, 0.0]

    key = scene.add_light(myth.DirectionalLight(color=[0.96, 0.97, 1.0], intensity=1.8))
    key.position = [7.0, 9.0, 6.0]
    key.look_at([0.0, 1.4, 0.0])

    ring_light = scene.add_light(
        myth.PointLight(color=[0.35, 0.92, 1.0], intensity=2.1, range=22.0)
    )
    ring_light.position = [0.0, 4.2, 4.5]

    palette = [
        myth.PhysicalMaterial(
            color="#0d1722",
            roughness=0.16,
            metalness=0.0,
            emissive=[0.35, 0.86, 1.0],
            emissive_intensity=4.0,
        ),
        myth.PhysicalMaterial(
            color="#1f0f26",
            roughness=0.18,
            metalness=0.0,
            emissive=[1.0, 0.42, 0.82],
            emissive_intensity=3.8,
        ),
        myth.PhysicalMaterial(
            color="#25190d",
            roughness=0.18,
            metalness=0.0,
            emissive=[1.0, 0.82, 0.32],
            emissive_intensity=3.6,
        ),
    ]

    for index in range(24):
        orb = scene.add_mesh(
            myth.SphereGeometry(radius=0.32, width_segments=32, height_segments=16),
            palette[index % len(palette)],
        )
        orb_nodes.append(orb)

    camera_node = scene.add_camera(myth.PerspectiveCamera(fov=45.0, near=0.1))
    camera_node.position = [0.0, 2.8, 9.5]
    camera_node.look_at([0.0, 1.4, 0.0])
    scene.active_camera = camera_node

    print("=== Custom Post FX Demo ===")
    print("Controls:")
    print("  Space   - Toggle the custom post effect")
    print("  Mouse   - Orbit camera")


@app.update
def on_update(ctx: myth.Engine, frame: myth.FrameState):
    global fps_accum_time, fps_accum_frames

    inp = ctx.input
    time = ctx.time

    if inp.key_down("Space"):
        post_pass.enabled = not post_pass.enabled
        print(f"Custom post FX: {'ON' if post_pass.enabled else 'OFF'}")

    orbit.update(camera_node, frame.dt)

    for index, orb in enumerate(orb_nodes):
        angle = time * (0.48 + index * 0.01) + index * 0.37
        radius = 2.6 + (index % 6) * 0.45
        height = 1.5 + math.sin(time * 1.6 + index * 0.31) * 1.25
        orb.position = [math.cos(angle) * radius, height, math.sin(angle) * radius]

    ring_light.position = [math.cos(time) * 4.8, 3.5 + math.sin(time * 1.4) * 0.8, math.sin(time) * 4.8]

    fps_accum_time += frame.dt
    fps_accum_frames += 1
    if fps_accum_time >= 0.5:
        fps = fps_accum_frames / fps_accum_time
        mode = "Custom Post FX" if post_pass.enabled else "Raw Scene"
        ctx.set_title(f"Custom Post FX | FPS: {fps:.0f} | Mode: {mode}")
        fps_accum_time = 0.0
        fps_accum_frames = 0


app.run()