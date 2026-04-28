"""
Myth Engine — Dynamic Video Texture Example
===========================================

Streams frames from ``examples/assets/demo.mp4`` into a dynamic Myth texture
without reallocating the engine-side image buffer every frame.

Usage:
    pip install maturin opencv-python
    maturin develop --release
    python examples/video_texture.py
"""

import atexit
import math

import myth

from __asset_utils import get_asset

try:
    import cv2
    import numpy as np
except ImportError as exc:  # pragma: no cover - example guard
    raise SystemExit(
        "This example requires opencv-python. Install it with: pip install opencv-python"
    ) from exc


app = myth.App(
    title="Myth Engine — Dynamic Video Texture",
    render_path=myth.RenderPath.BASIC,
    vsync=False,
)
app.clear_color = [0.02, 0.02, 0.03, 1.0]

video_capture = None
video_fps = 30.0
frame_accumulator = 0.0
seconds_per_frame = 1.0 / 30.0
video_texture = None
video_plane = None
frame_buffer = None
frame_view = None


def read_next_bgr_frame():
    global video_capture

    ok, frame = video_capture.read()
    if not ok:
        video_capture.set(cv2.CAP_PROP_POS_FRAMES, 0)
        ok, frame = video_capture.read()
        if not ok:
            raise RuntimeError("Failed to decode any frame from demo.mp4")

    return frame


def blit_next_frame():
    global frame_buffer, frame_view

    frame = read_next_bgr_frame()
    cv2.cvtColor(frame, cv2.COLOR_BGR2RGBA, dst=frame_view)
    return frame_buffer


@atexit.register
def cleanup_video_capture():
    global video_capture
    if video_capture is not None:
        video_capture.release()
        video_capture = None


@app.init
def on_init(ctx: myth.Engine):
    global video_capture, video_fps, seconds_per_frame, video_texture, video_plane
    global frame_buffer, frame_view

    scene = ctx.create_scene()
    scene.set_background_color(0.02, 0.02, 0.03)

    video_capture = cv2.VideoCapture(get_asset("demo.mp4"))
    if not video_capture.isOpened():
        raise RuntimeError("Failed to open examples/assets/demo.mp4")

    video_fps = video_capture.get(cv2.CAP_PROP_FPS) or 30.0
    seconds_per_frame = 1.0 / max(video_fps, 1.0)

    first_frame = read_next_bgr_frame()
    frame_height, frame_width = first_frame.shape[:2]

    frame_buffer = bytearray(frame_width * frame_height * 4)
    frame_view = np.frombuffer(frame_buffer, dtype=np.uint8).reshape(
        (frame_height, frame_width, 4)
    )
    cv2.cvtColor(first_frame, cv2.COLOR_BGR2RGBA, dst=frame_view)

    video_texture = ctx.create_dynamic_texture(
        "demo-video",
        frame_width,
        frame_height,
        frame_buffer,
        color_space="srgb",
        generate_mipmaps=False,
    )

    material = myth.UnlitMaterial(color=[1.0, 1.0, 1.0])
    material.set_map(video_texture)

    plane_height = 2.25
    plane_width = plane_height * frame_width / frame_height
    video_plane = scene.add_mesh(
        myth.PlaneGeometry(width=plane_width, height=plane_height),
        material,
    )

    camera = scene.add_camera(myth.PerspectiveCamera(fov=45, near=0.1))
    camera.position = [0.0, 0.0, 4.0]
    camera.look_at([0.0, 0.0, 0.0])
    scene.active_camera = camera

# FPS counter
fps_interval = 0.5  # seconds between updates
fps_accum_time = 0.0
fps_accum_frames = 0

@app.update
def on_update(ctx: myth.Engine, frame: myth.FrameState):
    global frame_accumulator, video_plane
    global fps_accum_time, fps_accum_frames

    frame_accumulator += frame.dt
    while frame_accumulator >= seconds_per_frame:
        video_texture.update_data(blit_next_frame())
        frame_accumulator -= seconds_per_frame

    if video_plane is not None:
        video_plane.rotation = [0.0, math.sin(frame.time * 0.75) * 0.5, math.pi]

    # FPS display
    fps_accum_time += frame.dt
    fps_accum_frames += 1
    if fps_accum_time >= fps_interval:
        fps = fps_accum_frames / fps_accum_time
        ctx.set_title(f"Myth Engine — Python Demo | FPS: {fps:.1f}")
        fps_accum_time = 0.0
        fps_accum_frames = 0


app.run()