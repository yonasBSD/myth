//! Procedural macros for the Myth engine material system.
//!
//! Provides the [`myth_material`] attribute macro that transforms a clean,
//! declarative material definition into a production-ready material type with:
//!
//! - Concurrent-safe GPU buffer management via [`CpuBuffer`] and [`RwLock`]
//! - Automatic version tracking for pipeline cache invalidation
//! - Generated getter/setter methods with fast-path optimizations
//! - Auto-generated uniform struct with std140 padding
//! - Full [`MaterialTrait`] and [`RenderableMaterialTrait`] implementations
//!
//! # Example
//!
//! ```rust,ignore
//! use myth_macros::myth_material;
//!
//! #[myth_material(shader = "entry/main/unlit")]
//! pub struct UnlitMaterial {
//!     /// Base color.
//!     #[uniform(default = "Vec4::ONE")]
//!     pub color: Vec4,
//!
//!     /// Opacity value.
//!     #[uniform(default = "1.0")]
//!     pub opacity: f32,
//!
//!     /// The color map.
//!     #[texture]
//!     pub map: TextureSlot,
//! }
//! ```

use proc_macro::TokenStream;

mod codegen;
mod gpu_struct_codegen;
mod gpu_struct_parse;
mod layout;
mod main_entry;
mod parse;

/// Transforms a declarative material struct into a complete engine material type.
///
/// # Struct-level Attributes
///
/// | Attribute | Required | Description |
/// |-----------|----------|-------------|
/// | `shader = "path"` | Yes | Shader template path |
/// | `shader_src = EXPR` | No | Embedded WGSL source used for lazy registration |
/// | `crate_path = "path"` | No | Path to `myth_resources` (default: `myth_resources`) |
///
/// # Field Attributes
///
/// | Attribute | Description |
/// |-----------|-------------|
/// | `#[uniform]` | Exposes a uniform struct field as a get/set property |
/// | `#[uniform(default = "expr")]` | Same, with a custom default value |
/// | `#[uniform(hidden)]` | Includes in uniform struct without generating accessors |
/// | `#[uniform(skip_builder)]` | Skips the generated `with_xxx` builder while keeping accessors |
/// | `#[texture]` | Declares a texture slot with automatic GPU binding |
/// | `#[internal(...)]` | Preserves a field in the generated struct |
///
/// ## `#[internal]` options
///
/// - `default = "expr"` — Default value for construction
/// - `clone_with = "expr"` — Custom clone expression (receives `&Self`)
///
/// # Generated Code
///
/// The macro replaces the annotated struct with:
///
/// 1. **Uniform struct** — `{Name}Uniforms` with std140 padding, `Pod`/`Zeroable`/`GpuData`/`WgslStruct`
/// 2. **TextureSet struct** — `{Name}TextureSet` containing all texture slots
/// 3. **Material struct** — Rewritten with `CpuBuffer`, `RwLock`, `AtomicU64` internals
/// 4. **Material defaults** — `Default` backed by the generated uniform defaults
/// 5. **Constructor** — `from_uniforms(uniforms) -> Self`
/// 6. **Settings API** — `set_xxx` / `with_xxx` for simple render-state toggles
/// 7. **Uniform accessors** — Per-field `set_xxx` / `xxx` / `with_xxx`
/// 8. **Texture accessors** — Per-slot `set_xxx`, `xxx`, `with_xxx`, `configure_xxx`
/// 9. **Clone impl** — Deep clone with atomic version snapshot
/// 10. **Trait impls** — `MaterialTrait` + `RenderableMaterialTrait`
#[proc_macro_attribute]
pub fn myth_material(attr: TokenStream, item: TokenStream) -> TokenStream {
    let args = syn::parse_macro_input!(attr as parse::MaterialAttrs);
    let input = syn::parse_macro_input!(item as syn::DeriveInput);

    match codegen::generate(args, input) {
        Ok(tokens) => tokens.into(),
        Err(err) => err.to_compile_error().into(),
    }
}

/// Transforms a GPU data struct into a fully aligned, GPU-ready type.
///
/// Automatically computes std140 memory layout, inserts padding fields,
/// and generates trait implementations for GPU upload and WGSL code generation.
///
/// # Struct-level Attributes
///
/// | Attribute | Required | Description |
/// |-----------|----------|-------------|
/// | `dynamic_offset = true` | No | Pad to 256-byte multiple for dynamic uniform buffers |
/// | `crate_path = "path"` | No | Path to `myth_resources` (default: `myth_resources`) |
///
/// # Field Attributes
///
/// | Attribute | Description |
/// |-----------|-------------|
/// | `#[default(expr)]` | Custom default value for the field |
///
/// Fields whose names start with `__` are included in the Rust struct and
/// memory layout but excluded from the generated WGSL struct definition.
///
/// # Generated Code
///
/// 1. **Struct** — `#[repr(C)]` with auto-inserted padding, `Pod`/`Zeroable` derives
/// 2. **`Default`** — Uses `#[default(...)]` values or `Default::default()`
/// 3. **`WgslType`** — WGSL type name and nested definition collection
/// 4. **`WgslStruct`** — Top-level WGSL struct definition generation
/// 5. **`GpuData`** — Byte-level access for GPU buffer upload
///
/// # Example
///
/// ```rust,ignore
/// use myth_macros::gpu_struct;
///
/// #[gpu_struct]
/// pub struct EnvironmentUniforms {
///     #[default(Vec3::ZERO)]
///     pub ambient_light: Vec3,
///     #[default(0)]
///     pub num_lights: u32,
///     #[default(1.0)]
///     pub env_map_intensity: f32,
///     pub env_map_rotation: f32,
///     pub env_map_max_mip_level: f32,
/// }
///
/// #[gpu_struct(dynamic_offset = true)]
/// pub struct DynamicModelUniforms {
///     pub world_matrix: Mat4,
///     // Auto-padded to 256-byte boundary
/// }
/// ```
#[proc_macro_attribute]
pub fn gpu_struct(attr: TokenStream, item: TokenStream) -> TokenStream {
    let args = syn::parse_macro_input!(attr as gpu_struct_parse::GpuStructAttrs);
    let input = syn::parse_macro_input!(item as syn::DeriveInput);

    match gpu_struct_codegen::generate(args, input) {
        Ok(tokens) => tokens.into(),
        Err(err) => err.to_compile_error().into(),
    }
}

/// Generates platform-specific entry points for Myth applications.
///
/// The annotated function becomes the shared application body, while the macro
/// expands to native and WASM entry points that initialize logging and panic
/// hooks consistently across platforms.
///
/// # Supported Signatures
///
/// - `fn main()`
/// - `fn main() -> Result<(), E>`
/// - `async fn main()`
/// - `async fn main() -> Result<(), E>`
#[proc_macro_attribute]
pub fn main(attr: TokenStream, item: TokenStream) -> TokenStream {
    if !attr.is_empty() {
        return syn::Error::new(
            proc_macro2::Span::call_site(),
            "#[myth::main] does not accept arguments",
        )
        .to_compile_error()
        .into();
    }

    let input = syn::parse_macro_input!(item as syn::ItemFn);

    match main_entry::generate(input) {
        Ok(tokens) => tokens.into(),
        Err(err) => err.to_compile_error().into(),
    }
}
