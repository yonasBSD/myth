const BLUE_NOISE_SIZE: u32 = 64u;
const BLUE_NOISE_INV_SIZE: f32 = 1.0 / 64.0;

fn get_blue_noise(coord: vec2<u32>, frame_index: u32) -> vec4<f32> {
    let wrapped = coord % vec2<u32>(BLUE_NOISE_SIZE);
    let uv = (vec2<f32>(wrapped) + vec2<f32>(0.5, 0.5)) * BLUE_NOISE_INV_SIZE;

$$ if HIGH_END_NOISE is defined
    let layer = i32(frame_index & 63u);
    return textureSampleLevel(t_blue_noise, s_blue_noise, uv, layer, 0.0);
$$ else
    let base_noise = textureSampleLevel(t_blue_noise, s_blue_noise, uv, 0.0);
    let temporal_offset = vec4<f32>(0.61803398875, 0.75487766624, 0.56984029, 0.43816197)
        * f32(frame_index & 1023u);
    return fract(base_noise + temporal_offset);
$$ endif
}