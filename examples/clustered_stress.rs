//! [gallery]
//! name = "Clustered Forward Stress"
//! category = "Performance"
//! description = "A BasicForward stress scene with hundreds of animated point lights to inspect clustered forward-lighting scalability."
//! instructions = "Mouse drag orbit camera\nScroll zoom\nWatch FPS with 192 animated point lights"
//! order = 365
//!

use std::f32::consts::TAU;

use myth::prelude::*;
use myth::render::RenderPath;
use myth_dev_utils::FpsCounter;

const LIGHT_LAYERS_X: usize = 12;
const LIGHT_LAYERS_Y: usize = 4;
const LIGHT_LAYERS_Z: usize = 4;

struct StressLight {
    node: NodeHandle,
    base: Vec3,
    phase: f32,
    amplitude: f32,
}

struct ClusteredStressDemo {
    controls: OrbitControls,
    fps_counter: FpsCounter,
    lights: Vec<StressLight>,
    time: f32,
}

impl AppHandler for ClusteredStressDemo {
    fn init(engine: &mut Engine, _window: &dyn Window) -> Self {
        let scene = engine.scene_manager.create_active();
        scene.environment.set_ambient_light(Vec3::splat(0.004));
        scene.background.set_mode(BackgroundMode::gradient(
            Vec4::new(0.025, 0.03, 0.045, 1.0),
            Vec4::new(0.004, 0.006, 0.01, 1.0),
        ));

        let floor = scene.spawn_plane(
            44.0,
            44.0,
            PhongMaterial::new(Vec4::new(0.14, 0.16, 0.19, 1.0)).with_side(Side::Double),
            &engine.assets,
        );
        scene
            .node(&floor)
            .set_rotation(Quat::from_rotation_x(-std::f32::consts::FRAC_PI_2))
            .set_position(0.0, -0.45, 0.0)
            .set_receive_shadows(false);

        for z in -4..=4 {
            for x in -4..=4 {
                let roughness = ((x + 4) as f32 / 8.0) * 0.7 + 0.15;
                let metalness = ((z + 4) as f32 / 8.0) * 0.6;
                let color = Vec4::new(
                    0.18 + (x + 4) as f32 * 0.06,
                    0.22 + (z + 4) as f32 * 0.04,
                    0.36 + (x + z + 8) as f32 * 0.02,
                    1.0,
                );
                let node = if (x + z) % 2 == 0 {
                    scene.spawn_box(
                        0.8,
                        0.8,
                        0.8,
                        PhysicalMaterial::new(color)
                            .with_roughness(roughness)
                            .with_metalness(metalness),
                        &engine.assets,
                    )
                } else {
                    scene.spawn_sphere(
                        0.48,
                        PhysicalMaterial::new(color)
                            .with_roughness(roughness)
                            .with_metalness(metalness),
                        &engine.assets,
                    )
                };
                scene
                    .node(&node)
                    .set_position(x as f32 * 2.2, 0.35, z as f32 * 2.2)
                    .set_shadows(false, true);
            }
        }

        let mut lights = Vec::with_capacity(LIGHT_LAYERS_X * LIGHT_LAYERS_Y * LIGHT_LAYERS_Z);
        for ix in 0..LIGHT_LAYERS_X {
            for iy in 0..LIGHT_LAYERS_Y {
                for iz in 0..LIGHT_LAYERS_Z {
                    let color_index =
                        ix * LIGHT_LAYERS_Y * LIGHT_LAYERS_Z + iy * LIGHT_LAYERS_Z + iz;
                    let hue = color_index as f32
                        / (LIGHT_LAYERS_X * LIGHT_LAYERS_Y * LIGHT_LAYERS_Z) as f32;
                    let color = hsv_to_rgb(hue, 0.78, 1.0);
                    let light = scene.add_light(Light::new_point(color, 1.0, 4.8));

                    let base = Vec3::new(
                        -11.0 + ix as f32 * 2.0,
                        1.4 + iy as f32 * 1.25,
                        -6.0 + iz as f32 * 4.0,
                    );
                    scene.node(&light).set_position(base.x, base.y, base.z);
                    lights.push(StressLight {
                        node: light,
                        base,
                        phase: (color_index as f32 / 17.0) * TAU,
                        amplitude: 0.35 + iy as f32 * 0.08,
                    });
                }
            }
        }

        let camera_pos = Vec3::new(0.0, 10.0, 19.0);
        let target = Vec3::new(0.0, 1.5, 0.0);
        let cam = scene.add_camera(Camera::new_perspective(50.0, 16.0 / 9.0, 0.1));
        scene
            .node(&cam)
            .set_position(camera_pos.x, camera_pos.y, camera_pos.z)
            .look_at(target);
        scene.active_camera = Some(cam);

        let mut controls = OrbitControls::new(camera_pos, target);
        controls.min_distance = 10.0;
        controls.max_distance = 34.0;

        Self {
            controls,
            fps_counter: FpsCounter::new(),
            lights,
            time: 0.0,
        }
    }

    fn update(&mut self, engine: &mut Engine, window: &dyn Window, frame: &FrameState) {
        let Some(scene) = engine.scene_manager.active_scene_mut() else {
            return;
        };

        self.time += frame.dt;

        for light in &self.lights {
            let wobble_x = (self.time * 0.55 + light.phase).sin() * light.amplitude;
            let wobble_y = (self.time * 1.2 + light.phase * 0.5).sin() * (light.amplitude * 0.75);
            let wobble_z = (self.time * 0.85 + light.phase * 1.3).cos() * light.amplitude;
            scene.node(&light.node).set_position(
                light.base.x + wobble_x,
                light.base.y + wobble_y,
                light.base.z + wobble_z,
            );
        }

        if let Some((transform, camera)) = scene.query_main_camera_bundle() {
            self.controls
                .update(transform, &engine.input, camera.fov(), frame.dt);
        }

        if let Some(fps) = self.fps_counter.update() {
            window.set_title(&format!(
                "Clustered Forward Stress | {} point lights | FPS: {:.2}",
                self.lights.len(),
                fps
            ));
        }
    }
}

fn hsv_to_rgb(h: f32, s: f32, v: f32) -> Vec3 {
    let h6 = (h.fract() * 6.0).clamp(0.0, 6.0 - f32::EPSILON);
    let i = h6.floor() as i32;
    let f = h6 - i as f32;
    let p = v * (1.0 - s);
    let q = v * (1.0 - f * s);
    let t = v * (1.0 - (1.0 - f) * s);

    match i {
        0 => Vec3::new(v, t, p),
        1 => Vec3::new(q, v, p),
        2 => Vec3::new(p, v, t),
        3 => Vec3::new(p, q, v),
        4 => Vec3::new(t, p, v),
        _ => Vec3::new(v, p, q),
    }
}

#[myth::main]
fn main() -> myth::Result<()> {
    App::new()
        .with_settings(RendererSettings {
            path: RenderPath::BasicForward,
            vsync: false,
            ..Default::default()
        })
        .run::<ClusteredStressDemo>()
}
