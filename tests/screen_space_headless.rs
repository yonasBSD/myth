use myth::prelude::*;

fn assert_not_black(pixels: &[u8], label: &str) {
    let any_color = pixels
        .chunks_exact(4)
        .any(|px| px[0] > 0 || px[1] > 0 || px[2] > 0);
    assert!(any_color, "{label}: rendered image is entirely black");
}

#[test]
fn screen_space_effects_headless_smoke() {
    let mut engine = Engine::default();
    let width: u32 = 128;
    let height: u32 = 128;

    pollster::block_on(engine.init_headless(width, height, None)).expect("headless init failed");

    let scene = engine.scene_manager.create_active();
    scene.ssao.set_enabled(true);
    scene.ssgi.set_enabled(true);
    scene.ssgi.set_quality(SsgiQuality::Low);
    scene.ssr.set_enabled(true);
    scene.ssr.set_max_steps(12);
    scene.ssr.set_spatial_radius(1);

    let floor = PhysicalMaterial::new(Vec4::new(0.75, 0.75, 0.78, 1.0))
        .with_roughness(0.28)
        .with_metalness(0.0);
    let box_mat = PhysicalMaterial::new(Vec4::new(0.85, 0.3, 0.22, 1.0))
        .with_roughness(0.14)
        .with_metalness(0.92);

    let floor_node = scene.spawn_box(6.0, 0.2, 6.0, floor, &engine.assets);
    scene.node(&floor_node).set_position(0.0, -1.2, 0.0);

    let box_node = scene.spawn_box(1.2, 1.2, 1.2, box_mat, &engine.assets);
    scene.node(&box_node).set_position(0.0, 0.0, 0.0);

    scene.add_light(Light::new_directional(Vec3::ONE, 4.0));

    let cam = scene.add_camera(Camera::new_perspective(
        45.0,
        width as f32 / height as f32,
        0.1,
    ));
    scene
        .node(&cam)
        .set_position(0.0, 1.4, 4.5)
        .look_at(Vec3::new(0.0, -0.2, 0.0));
    scene.active_camera = Some(cam);

    for _ in 0..3 {
        engine.update(1.0 / 60.0);
        engine.render_active_scene();
    }

    let pixels = engine.readback_pixels().expect("readback failed");
    assert_eq!(pixels.len(), (width * height * 4) as usize);
    assert_not_black(&pixels, "screen_space_effects_headless_smoke");
}
