// ── Standard Fragment Output ────────────────────────────────────────────
//
// Provides a unified `FragmentOutput` struct and a convenience
// `pack_fragment_output` helper so that ALL material shaders (built-in
// and custom) produce an output layout that matches the Opaque Pass's
// color attachment configuration.
//
// When `HAS_MRT_SPECULAR_DATA` is defined the struct contains an additional
// `@location(1)` target for the shared specular-data bus. Materials that do not
// perform their own specular split should call `pack_fragment_output`.
// When `HAS_MRT_MATERIAL_DATA` is defined an additional material-data attachment
// is appended after the optional specular MRT.
// which fills extra MRT targets with safe default values.

struct FragmentOutput {
    @location(0) color: vec4<f32>,
$$ if HAS_MRT_SPECULAR_DATA is defined
    @location(1) specular_data: vec4<f32>,
$$ endif
$$ if HAS_MRT_MATERIAL_DATA is defined and HAS_MRT_SPECULAR_DATA is defined
    @location(2) material_data: vec4<f32>,
$$ elif HAS_MRT_MATERIAL_DATA is defined
    @location(1) material_data: vec4<f32>,
$$ endif
};

/// Packs a single main color into a valid `FragmentOutput`.
///
/// Extra MRT targets are filled with safe defaults so that
/// non-PBR materials remain pipeline-compatible without any manual work.
fn pack_fragment_output(main_color: vec4<f32>) -> FragmentOutput {
    var out: FragmentOutput;
    out.color = main_color;
$$ if HAS_MRT_SPECULAR_DATA is defined
    out.specular_data = vec4<f32>(0.0);
$$ endif
$$ if HAS_MRT_MATERIAL_DATA is defined
    out.material_data = vec4<f32>(main_color.rgb, 1.0);
$$ endif
    return out;
}
