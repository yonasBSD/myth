[中文](AdvancedCustomization_zh.md)

---

# Myth Advanced Customization Guide

Myth provides a robust set of extension mechanisms for advanced users:

1. Custom mesh materials through `#[myth_material]` or manual `RenderableMaterialTrait` implementations.
2. Custom WGSL templates through named built-in templates, registered named templates, or inline WGSL.
3. Custom fullscreen and compute graph nodes through the template-pass system.

This guide explains the current contract of those systems, with emphasis on the engine-generated WGSL interface that you can rely on today.

## 1. Choose the Right Extension Surface

| Goal | Recommended API | What you write | Good examples |
| --- | --- | --- | --- |
| Standard mesh material that still participates in the normal geometry pipeline | `#[myth_material(shader = "...", shader_src = WGSL)]` | Only the material-specific WGSL body | [examples/custom_material_hologram.rs](../examples/custom_material_hologram.rs), [examples/custom_material_dissolve.rs](../examples/custom_material_dissolve.rs) |
| Mesh material with full control over the complete WGSL template | `#[myth_material(shader = "...", shader_template_src = WGSL)]` | Full template source | Your own advanced material templates |
| Material that needs custom Rust-side resource logic | Manual `RenderableMaterialTrait` | Full Rust trait impl plus WGSL | Built-in materials in `myth_resources::material` |
| Fullscreen post-processing pass | `RenderPassBuilder::fullscreen(...)` | Fullscreen WGSL + graph bindings | [examples/custom_post_fx.rs](../examples/custom_post_fx.rs) |
| Compute utility or GPU data-generation pass | `ComputePassBuilder::new(...)` | Compute WGSL + graph bindings | [examples/gpu_driven_particle_lights.rs](../examples/gpu_driven_particle_lights.rs) |
| Override a named template used by a `ShaderSource::File("name")` lookup | `renderer.register_shader_template(name, source)` | Full template source | Engine-owned or app-owned named templates |

The most important rule is simple:

- Use `shader_src` when you want a normal material in Myth's standard geometry pipeline.
- Use `shader_template_src` or template passes when you want to own the full WGSL contract yourself.

## 2. Shader Template Model

### 2.1 Named Templates and Inline Sources

Internally, Myth distinguishes two source kinds:

| Source kind | Meaning | Typical user-facing entry |
| --- | --- | --- |
| `ShaderSource::File("name")` | Look up a named template. Registered overrides take priority, otherwise built-in embedded assets are used. | Built-in material templates, `RenderPassBuilder::shader_template(...)`, `ComputePassBuilder::shader_template(...)` |
| `ShaderSource::Inline { ... }` | Use a WGSL string supplied directly by the caller. | `shader_src`, `shader_template_src`, `inline_shader_template(...)` |

This matters because embedded custom material shaders now travel with the material itself. They are not registered into the global template map first.

### 2.2 Template Mode vs Material-Body Mode

Myth also distinguishes two interpretation modes:

| Mode | Meaning | How to get it |
| --- | --- | --- |
| `ShaderTemplateMode::Template` | The source is a full WGSL template. You own the entire entry-point structure. | `shader_template_src`, `inline_shader_template(...)`, `register_shader_template(...)` |
| `ShaderTemplateMode::MaterialBody` | The source is only the material-specific geometry shader body. Myth wraps it with the standard material prelude automatically. | `shader_src` |

`shader_src` is therefore the default path for most advanced material authors. It gives you custom shading without forcing you to restate the engine's standard boilerplate every time.

### 2.3 Template Syntax

Myth uses Minijinja with WGSL-friendly delimiters:

| Syntax | Meaning |
| --- | --- |
| `{{ name }}` | Substitute a variable or injected code block |
| `{$ include 'path' $}` | Include a built-in shader chunk |
| `$$ if SOME_DEFINE is defined` | Conditional line statement |

The environment also exposes `loc.next()` for allocating `@location(...)` values in templates that generate structs like `VertexOutput`.

### 2.4 Automatically Injected Template Context

Every shader compilation path can receive flattened `defines` and `code_blocks`. The standard geometry pipeline injects the following keys:

| Injected key | Meaning |
| --- | --- |
| `vertex_input_code` | The auto-generated `VertexInput` WGSL struct derived from the current `Geometry` layout |
| `binding_code` | The concatenated WGSL declarations for the active bind groups |
| `scene_lighting_structs` | Canonical scene-light WGSL structs, including `Struct_lights` and `LightBufferMetadata` |
| `clustered_lighting_structs` | Additional clustered-lighting structs, injected when clustered shading is enabled |

In material-body mode, Myth prepends those blocks automatically together with:

- `core/vertex_output`
- `core/fragment_output`

That is why body-mode shaders can directly author `vs_main`, `fs_main`, `VertexOutput`, `FragmentOutput`, and `pack_fragment_output(...)` without writing the full scaffold themselves.

### 2.5 Where Defines Come From

The final shader define set is merged from multiple layers:

| Define source | Examples |
| --- | --- |
| Material settings and textures | `ALPHA_MODE`, `HAS_MAP`, `MAP_UV` |
| Geometry layout/features | `HAS_POSITION`, `HAS_NORMAL`, `HAS_UV`, `HAS_COLOR`, `HAS_MORPH_TARGETS`, `SUPPORT_SKINNING` |
| Scene state | `HAS_SHADOWS`, `USE_SSAO`, `USE_SSS`, `USE_SSR`, `DEBUG_VIEW_ALBEDO` |
| Per-item state | `HAS_SKINNING`, `RECEIVE_SHADOWS` |
| Pipeline/pass state | `USE_CLUSTERED_SHADING`, `HDR`, `IN_TRANSPARENT_PASS`, `HAS_MRT_SSSS`, `ALPHA_TO_COVERAGE`, `SHADOW_PASS` |

You should treat those defines as part of the supported shader authoring surface, especially in body-mode materials and template passes.

## 3. Custom Materials with `#[myth_material]`

The `#[myth_material]` macro is the primary high-level entry point for custom materials.

### 3.1 What the Macro Generates

For a declarative material struct, the macro generates:

1. A GPU-ready uniform struct with std140-compatible layout.
2. Internal CPU buffer and version tracking for pipeline invalidation.
3. Generated getters, setters, and `with_xxx(...)` builders.
4. Texture slot accessors and configuration helpers.
5. `Default` and `from_uniforms(...)` construction helpers.
6. `MaterialTrait` and `RenderableMaterialTrait` implementations.
7. Automatic material binding declarations for the renderer.
8. Automatic shader-define generation based on texture presence and render settings.

### 3.2 Struct-Level Attributes

| Attribute | Meaning |
| --- | --- |
| `shader = "name"` | Required logical shader name |
| `shader_src = WGSL_EXPR` | Embedded material body. Myth wraps it with the standard geometry-material prelude. |
| `shader_template_src = WGSL_EXPR` | Embedded full template source. You own the complete WGSL contract. |
| `crate_path = "..."` | Override the `myth_resources` path used by the macro |

### 3.3 Field Attributes

| Attribute | Meaning |
| --- | --- |
| `#[uniform]` | Generate a uniform field and accessors |
| `#[uniform(default = "expr")]` | Same, with a default value |
| `#[uniform(hidden)]` | Include in the uniform struct without public accessors |
| `#[uniform(skip_builder)]` | Keep accessors, but skip the generated `with_xxx(...)` builder |
| `#[texture]` | Add a texture slot with automatic WGSL bindings and shader defines |
| `#[internal(...)]` | Keep a Rust-side field in the generated material type |

### 3.4 Minimal Body-Mode Example

```rust
use myth::prelude::*;
use myth::resources::myth_material;

const HOLO_SHADER: &str = r#"
@vertex
fn vs_main(in: VertexInput) -> VertexOutput {
    var out: VertexOutput;
    let world_pos = u_model.world_matrix * vec4<f32>(in.position.xyz, 1.0);
    out.position = u_render_state.view_projection * world_pos;
    out.world_position = world_pos.xyz / world_pos.w;

    $$ if HAS_NORMAL is defined
    out.geometry_normal = normalize(in.normal.xyz);
    out.normal = normalize(u_model.normal_matrix * in.normal.xyz);
    $$ endif

    return out;
}

@fragment
fn fs_main(in: VertexOutput) -> FragmentOutput {
    let pulse = 0.5 + 0.5 * sin(u_render_state.time * u_material.speed);
    let color = u_material.base_color.rgb * (0.4 + pulse * 0.6);
    return pack_fragment_output(vec4<f32>(color, u_material.opacity));
}
"#;

#[myth_material(shader = "examples/holo", shader_src = HOLO_SHADER)]
pub struct HoloMaterial {
    #[uniform(default = "Vec4::new(0.1, 0.8, 1.2, 1.0)")]
    pub base_color: Vec4,

    #[uniform(default = "1.0")]
    pub opacity: f32,

    #[uniform(default = "2.0")]
    pub speed: f32,
}
```

The current examples are richer, but conceptually they use exactly this contract. See [examples/custom_material_hologram.rs](../examples/custom_material_hologram.rs) and [examples/custom_material_dissolve.rs](../examples/custom_material_dissolve.rs).

### 3.5 What the Macro Automatically Adds to WGSL

For a material field like this:

```rust
#[texture]
pub map: TextureSlot,
```

Myth will automatically provide all of the following:

- Texture bindings `t_map` and `s_map`
- A transform field in `u_material` named `map_transform`
- A presence define `HAS_MAP`
- An optional `MAP_UV` define when the texture uses UV channel 1+

Likewise, every uniform field becomes a field inside `u_material` using the same Rust field name.

The generated `shader_defines()` implementation also adds render-setting defines like `ALPHA_MODE`, then calls `extra_defines(...)` so manual implementations can extend the final define set.

### 3.6 `shader_src` vs `shader_template_src`

Choose `shader_src` when:

- you want to stay inside the standard mesh-material pipeline
- you want automatic access to `VertexInput`, `VertexOutput`, `FragmentOutput`, `pack_fragment_output(...)`, light structs, and bind-group declarations
- you only need to customize shading logic, not the whole template scaffold

Choose `shader_template_src` when:

- you want full control over the complete WGSL template
- you need to own the exact order of includes and declarations
- you intentionally do not want the engine-managed material prelude

## 4. Engine-Generated WGSL Surface for Standard Geometry Materials

### 4.1 Standard Binding Groups

In the standard geometry path, Myth assembles `binding_code` from three auto-generated bind groups:

| Group | Typical variables | Source |
| --- | --- | --- |
| Group 0 | `u_render_state`, `u_environment`, `st_directional_lights`, `t_env_map`, `s_env_map`, `t_pmrem_map`, `s_pmrem_map`, `t_brdf_lut`, `s_brdf_lut` | Render state + scene/global bindings |
| Group 1 | `u_material`, `t_<texture>`, `s_<texture>` | Material bindings |
| Group 2 | `u_model`, `u_morph_targets`, `st_morph_positions`, `st_morph_normals`, `st_morph_tangents`, `st_skins`, `st_prev_skins` | Object, mesh, geometry, and skeleton bindings |

Exact availability depends on the current mesh and material. For example, morph and skinning bindings only appear when the mesh actually uses those features.

### 4.2 Geometry-Driven Inputs and Defines

`Geometry` attributes drive both vertex layout creation and geometry defines.

Current rules:

- Each attribute name becomes a field in the generated `VertexInput` struct.
- Each attribute name also generates a `HAS_<NAME>` define.
- Morph data generates `HAS_MORPH_TARGETS`, `HAS_MORPH_NORMALS`, and `HAS_MORPH_TANGENTS` when applicable.
- A geometry that contains both `joints` and `weights` gets `SUPPORT_SKINNING`.

This means custom geometry attributes can participate in custom shaders without any extra registry step. If your geometry has an attribute named `foo`, the shader can test `HAS_FOO` and read `in.foo`.

### 4.3 Scene-, Item-, and Pipeline-Level Defines

The renderer further layers in scene and pass state:

- Scene-level: `HAS_SHADOWS`, `USE_SSAO`, `USE_SCREEN_SPACE_FEATURES`, `USE_SSS`, `USE_SSR`, debug-view overrides
- Per-item: `HAS_SKINNING`, `RECEIVE_SHADOWS`
- Pipeline-level: `USE_CLUSTERED_SHADING`, `HDR`, `IN_TRANSPARENT_PASS`, `HAS_MRT_SSSS`, `ALPHA_TO_COVERAGE`

Those defines are what let one WGSL template adapt to multiple render paths and feature combinations.

### 4.4 Body-Mode Output Types and Helpers

In `shader_src` body mode, Myth also injects the standard output helpers:

- `VertexOutput`
- `FragmentOutput`
- `pack_fragment_output(...)`

`VertexOutput` already contains the common world-space data and all material-map UV varyings that are gated by `HAS_*` defines.

If your material uses `#[texture]` fields and wants the standard transformed UV varyings, include the built-in helper in your vertex shader:

```wgsl
{$ include 'mixins/uv_vertex' $}
```

That mixin populates fields like `out.map_uv`, `out.normal_map_uv`, and so on from `u_material.*_transform` and the relevant UV set.

### 4.5 Recommended Body-Mode Checklist

For a robust custom mesh material, start with this checklist:

1. Use `shader_src` unless you truly need full-template control.
2. Read common engine data from `u_render_state`, `u_model`, and `u_material`.
3. Use `pack_fragment_output(...)` unless you intentionally manage MRT output yourself.
4. Include `mixins/uv_vertex` when your material has `#[texture]` fields.
5. Keep `opacity` and `alpha_test` uniforms if the material participates in alpha clipping or depth-prepass behavior.

## 5. Manual `RenderableMaterialTrait` Implementations

The macro is the best default, but Myth still keeps the lower-level material interface available.

Manual implementations are appropriate when you need to:

- control the exact Rust storage model yourself
- add unusual resource bindings that the macro does not describe well
- generate custom defines outside the macro's field-based rules
- opt out of the generated accessors/builders entirely

At minimum, a manual implementation needs to provide:

- `shader_name()`
- optionally `shader_template()` and `shader_template_mode()`
- `version()`
- `shader_defines()`
- `settings()`
- `define_bindings(...)`
- `uniform_buffer()` and `with_uniform_bytes(...)`

Use the macro until you can explain exactly why you need the manual path.

## 6. Template Pass System

Template passes are for work that is not naturally a `Material`:

- fullscreen post-processing
- utility compute jobs
- graph-local experimental rendering or data generation

### 6.1 Builder Phase vs Graph Phase

The system is intentionally split into two stages.

Builder phase:

- choose shader source (`shader_template(...)` or `inline_shader_template(...)`)
- declare static bind-group layout
- optionally inject compile-time defines/code via `shader_options(...)`
- build a reusable `TemplateFullscreenPass` or `TemplateComputePass`

Graph phase:

- insert the pass into the current RDG frame
- bind concrete graph textures, buffers, samplers, or tracked external resources

That split keeps pipeline compilation reusable while letting each frame provide different graph resources.

### 6.2 Fullscreen Example

Declaration:

```rust
let post_pass = RenderPassBuilder::fullscreen("Custom Post FX Pipeline")
    .inline_shader_template(CUSTOM_POST_SHADER_NAME, CUSTOM_POST_SHADER_TEMPLATE)
    .bind_texture_2d(0, 0, wgpu::ShaderStages::FRAGMENT, true)
    .bind_sampler(0, 1, wgpu::ShaderStages::FRAGMENT, wgpu::SamplerBindingType::Filtering)
    .color_target(wgpu::ColorTargetState {
        format: HDR_TEXTURE_FORMAT,
        blend: Some(wgpu::BlendState::REPLACE),
        write_mask: wgpu::ColorWrites::ALL,
    })
    .build(&mut engine.renderer);
```

Graph insertion:

```rust
let node = post_pass.build_node(
    builder,
    "Custom Post FX Pass",
    out,
    RenderTargetOps::DontCare,
    Some("CustomPostFX BindGroup"),
    |bindings| {
        bindings.bind_texture(0, 0, scene_color);
        bindings.bind_common_sampler(0, 1, CommonSampler::LinearClamp);
    },
);
```

See the full version in [examples/custom_post_fx.rs](../examples/custom_post_fx.rs).

### 6.3 Compute Example

Declaration:

```rust
let swarm_pass = ComputePassBuilder::new("GPU Particle Light Pipeline")
    .inline_shader_template(GPU_PARTICLE_LIGHT_SHADER_NAME, GPU_PARTICLE_LIGHT_SHADER_TEMPLATE)
    .shader_options(swarm_shader_options)
    .bind_uniform_buffer(0, 0, wgpu::ShaderStages::COMPUTE)
    .bind_storage_buffer(0, 1, wgpu::ShaderStages::COMPUTE, false)
    .bind_storage_buffer(0, 2, wgpu::ShaderStages::COMPUTE, false)
    .bind_storage_buffer(0, 3, wgpu::ShaderStages::COMPUTE, false)
    .build(&mut engine.renderer);
```

Graph insertion:

```rust
let node = swarm_pass.build_node(
    builder,
    "GPU Particle Light Pass",
    [GPU_LIGHT_COUNT.div_ceil(PARTICLE_LIGHT_WG_SIZE), 1, 1],
    Some("GPU Particle Light BG"),
    |bindings| {
        bindings.bind_tracked_buffer(0, 0, params_buffer);
        bindings.bind_buffer(0, 1, light_metadata);
        bindings.bind_buffer(0, 2, light_storage);
        bindings.bind_buffer(0, 3, indirect_count_buffer);
    },
);
```

See [examples/gpu_driven_particle_lights.rs](../examples/gpu_driven_particle_lights.rs) for the complete flow.

### 6.4 Important Template-Pass Rules

Keep these rules in mind:

1. Bind-group indices must start at 0 and be dense.
2. Inline template-pass shaders are used directly; they are not auto-registered first.
3. `shader_template("name")` performs a named lookup, so registered template overrides still apply there.
4. Template passes do not receive the standard material prelude. Their layout is exactly what you declare.

## 7. Named Template Overrides

Myth still supports named template overrides for advanced users:

```rust
engine.renderer.register_shader_template(
    "my/custom/template",
    include_str!("shaders/my_custom_template.wgsl"),
);
```

This is the low-level escape hatch for `ShaderSource::File("my/custom/template")` lookups.

Use it when:

- you want a reusable named template shared across multiple passes
- you want to override a named template path on purpose
- you are intentionally working at the raw-template layer

Do not use it for `shader_src` body-mode materials. Those embedded sources are already passed directly as inline shader source during pipeline creation.

## 8. Practical Pitfalls and Recommendations

1. Prefer `shader_src` for normal mesh materials. It gives you the most leverage for the least boilerplate.
2. Use `shader_template_src` only when you need full-template ownership.
3. If a `#[myth_material]` type has any `#[texture]` fields in a standalone module, make sure `Mat3Uniform` is in scope because hidden `*_transform` uniforms are generated for texture UV transforms.
4. Keep `opacity` and `alpha_test` in materials that expect depth-prepass-compatible alpha clipping.
5. Field names become WGSL identifiers. Renaming a Rust field also renames its shader-facing name.
6. If you need graph-local post effects or compute jobs, use template passes instead of forcing everything through `Material`.

## 9. Reference Examples

- [examples/custom_material_hologram.rs](../examples/custom_material_hologram.rs)
- [examples/custom_material_dissolve.rs](../examples/custom_material_dissolve.rs)
- [examples/custom_material_texture_flow.rs](../examples/custom_material_texture_flow.rs)
- [examples/custom_material_slope_blend.rs](../examples/custom_material_slope_blend.rs)
- [examples/custom_material_triplanar.rs](../examples/custom_material_triplanar.rs)
- [examples/custom_post_fx.rs](../examples/custom_post_fx.rs)
- [examples/gpu_driven_particle_lights.rs](../examples/gpu_driven_particle_lights.rs)

When in doubt, start from one of those examples and only drop to raw templates or manual trait implementations after the standard body-mode path becomes a real constraint.