use std::cell::RefCell;
use std::rc::Rc;
use std::sync::atomic::{AtomicU64, Ordering};

use pyo3::exceptions::{PyTypeError, PyValueError};
use pyo3::prelude::*;

use myth_engine::math::Vec4;
use myth_engine::renderer::HDR_TEXTURE_FORMAT;
use myth_engine::renderer::core::gpu::CommonSampler;
use myth_engine::renderer::graph::core::{
    HookStage, RenderPassBuilder, RenderTargetOps, TemplateFullscreenPass, TextureDesc,
};
use myth_engine::renderer::wgpu;
use myth_engine::resources::buffer::{BufferRef, CpuBuffer};
use myth_engine::resources::builder::ResourceBuilder;
use myth_engine::resources::material::{
    AlphaMode, Material, MaterialSettings, MaterialTrait, RenderableMaterialTrait,
    ShaderTemplateMode, Side, TextureSlot,
};
use myth_engine::resources::shader_defines::ShaderDefines;
use myth_engine::resources::texture::TextureSource;
use myth_engine::resources::uniforms::Mat3Uniform;
use myth_engine::{Engine, MaterialHandle, TextureHandle};

use crate::texture::PyTextureHandle;
use crate::with_engine;

fn leak_string(value: &str) -> &'static str {
    Box::leak(value.to_string().into_boxed_str())
}

fn leak_owned_string(value: String) -> &'static str {
    Box::leak(value.into_boxed_str())
}

fn hex_to_rgb(s: &str) -> PyResult<[f32; 3]> {
    let s = s.trim_start_matches('#');
    match s.len() {
        6 => {
            let r = u8::from_str_radix(&s[0..2], 16).unwrap_or(0);
            let g = u8::from_str_radix(&s[2..4], 16).unwrap_or(0);
            let b = u8::from_str_radix(&s[4..6], 16).unwrap_or(0);
            Ok([r as f32 / 255.0, g as f32 / 255.0, b as f32 / 255.0])
        }
        3 => {
            let r = u8::from_str_radix(&s[0..1], 16).unwrap_or(0);
            let g = u8::from_str_radix(&s[1..2], 16).unwrap_or(0);
            let b = u8::from_str_radix(&s[2..3], 16).unwrap_or(0);
            Ok([r as f32 / 15.0, g as f32 / 15.0, b as f32 / 15.0])
        }
        _ => Err(PyValueError::new_err("Invalid hex color")),
    }
}

fn parse_color_like(obj: &Bound<'_, PyAny>, default_w: f32) -> PyResult<[f32; 4]> {
    if let Ok(s) = obj.extract::<String>() {
        let [r, g, b] = hex_to_rgb(&s)?;
        return Ok([r, g, b, default_w]);
    }
    if let Ok(values) = obj.extract::<Vec<f32>>() {
        return match values.as_slice() {
            [x, y, z] => Ok([*x, *y, *z, default_w]),
            [x, y, z, w] => Ok([*x, *y, *z, *w]),
            _ => Err(PyValueError::new_err(
                "Expected '#RRGGBB', '#RGB', [x, y, z], or [x, y, z, w]",
            )),
        };
    }
    if let Ok((x, y, z, w)) = obj.extract::<(f32, f32, f32, f32)>() {
        return Ok([x, y, z, w]);
    }
    if let Ok((x, y, z)) = obj.extract::<(f32, f32, f32)>() {
        return Ok([x, y, z, default_w]);
    }

    Err(PyTypeError::new_err(
        "Expected '#RRGGBB', '#RGB', [x, y, z], or [x, y, z, w]",
    ))
}

fn parse_exact_vec4(obj: &Bound<'_, PyAny>) -> PyResult<[f32; 4]> {
    if let Ok(values) = obj.extract::<Vec<f32>>()
        && values.len() == 4
    {
        return Ok([values[0], values[1], values[2], values[3]]);
    }
    if let Ok((x, y, z, w)) = obj.extract::<(f32, f32, f32, f32)>() {
        return Ok([x, y, z, w]);
    }
    Err(PyTypeError::new_err(
        "Expected a 4-component vector [x, y, z, w]",
    ))
}

fn parse_side(name: &str) -> PyResult<Side> {
    match name.to_lowercase().as_str() {
        "front" => Ok(Side::Front),
        "back" => Ok(Side::Back),
        "double" | "both" => Ok(Side::Double),
        _ => Err(PyValueError::new_err(
            "side must be 'front', 'back', or 'double'",
        )),
    }
}

fn parse_alpha_mode(name: &str) -> PyResult<AlphaMode> {
    match name.to_lowercase().as_str() {
        "opaque" => Ok(AlphaMode::Opaque),
        "mask" => Ok(AlphaMode::Mask),
        "blend" => Ok(AlphaMode::Blend),
        "blend_mask" | "blendmask" => Ok(AlphaMode::BlendMask),
        _ => Err(PyValueError::new_err(
            "alpha_mode must be 'opaque', 'mask', 'blend', or 'blend_mask'",
        )),
    }
}

fn parse_shader_mode(name: &str) -> PyResult<ShaderTemplateMode> {
    match name.to_lowercase().as_str() {
        "body" | "material_body" | "materialbody" => Ok(ShaderTemplateMode::MaterialBody),
        "template" => Ok(ShaderTemplateMode::Template),
        _ => Err(PyValueError::new_err(
            "shader_mode must be 'body' or 'template'",
        )),
    }
}

#[myth_engine::resources::gpu_struct(crate_path = "myth_engine::resources")]
pub struct ShaderMaterialUniforms {
    pub base_color: Vec4,
    pub accent_color: Vec4,
    pub edge_color: Vec4,
    pub emissive_color: Vec4,
    #[default(1.0)]
    pub opacity: f32,
    pub alpha_test: f32,
    pub params0: Vec4,
    pub params1: Vec4,
    pub params2: Vec4,
    pub params3: Vec4,
    pub map_transform: Mat3Uniform,
}

fn default_uniforms() -> ShaderMaterialUniforms {
    ShaderMaterialUniforms {
        base_color: Vec4::ONE,
        accent_color: Vec4::ZERO,
        edge_color: Vec4::ZERO,
        emissive_color: Vec4::ZERO,
        opacity: 1.0,
        alpha_test: 0.0,
        params0: Vec4::ZERO,
        params1: Vec4::ZERO,
        params2: Vec4::ZERO,
        params3: Vec4::ZERO,
        map_transform: Mat3Uniform::IDENTITY,
        ..Default::default()
    }
}

#[derive(Debug)]
struct PyShaderMaterialRuntime {
    shader_name: &'static str,
    shader_source: Option<&'static str>,
    shader_mode: ShaderTemplateMode,
    uniforms: CpuBuffer<ShaderMaterialUniforms>,
    settings: parking_lot::RwLock<MaterialSettings>,
    version: AtomicU64,
    map: parking_lot::RwLock<TextureSlot>,
}

impl PyShaderMaterialRuntime {
    fn new(
        shader_name: &'static str,
        shader_source: Option<&'static str>,
        shader_mode: ShaderTemplateMode,
        uniforms: ShaderMaterialUniforms,
        settings: MaterialSettings,
        map: Option<TextureHandle>,
    ) -> Self {
        Self {
            shader_name,
            shader_source,
            shader_mode,
            uniforms: CpuBuffer::new(
                uniforms,
                wgpu::BufferUsages::UNIFORM | wgpu::BufferUsages::COPY_DST,
                Some("Python Shader Material Uniforms"),
            ),
            settings: parking_lot::RwLock::new(settings),
            version: AtomicU64::new(0),
            map: parking_lot::RwLock::new(TextureSlot::from(map)),
        }
    }

    fn bump_version(&self) {
        self.version.fetch_add(1, Ordering::Relaxed);
    }

    fn set_base_color(&self, value: [f32; 4]) {
        let mut uniforms = self.uniforms.write();
        uniforms.base_color = Vec4::from_array(value);
    }

    fn set_accent_color(&self, value: [f32; 4]) {
        let mut uniforms = self.uniforms.write();
        uniforms.accent_color = Vec4::from_array(value);
    }

    fn set_edge_color(&self, value: [f32; 4]) {
        let mut uniforms = self.uniforms.write();
        uniforms.edge_color = Vec4::from_array(value);
    }

    fn set_emissive_color(&self, value: [f32; 4]) {
        let mut uniforms = self.uniforms.write();
        uniforms.emissive_color = Vec4::from_array(value);
    }

    fn set_opacity(&self, value: f32) {
        let mut uniforms = self.uniforms.write();
        uniforms.opacity = value;
    }

    fn set_alpha_test(&self, value: f32) {
        let mut uniforms = self.uniforms.write();
        uniforms.alpha_test = value;
    }

    fn set_params(&self, slot: usize, value: [f32; 4]) {
        let mut uniforms = self.uniforms.write();
        let vec = Vec4::from_array(value);
        match slot {
            0 => uniforms.params0 = vec,
            1 => uniforms.params1 = vec,
            2 => uniforms.params2 = vec,
            3 => uniforms.params3 = vec,
            _ => {}
        }
    }

    fn set_side(&self, value: Side) {
        let mut settings = self.settings.write();
        if settings.side != value {
            settings.side = value;
            drop(settings);
            self.bump_version();
        }
    }

    fn set_alpha_mode(&self, value: AlphaMode) {
        let mut settings = self.settings.write();
        if settings.alpha_mode != value {
            settings.alpha_mode = value;
            drop(settings);
            self.bump_version();
        }
    }

    fn set_depth_write(&self, value: bool) {
        let mut settings = self.settings.write();
        if settings.depth_write != value {
            settings.depth_write = value;
            drop(settings);
            self.bump_version();
        }
    }

    fn set_depth_test(&self, value: bool) {
        let mut settings = self.settings.write();
        if settings.depth_test != value {
            settings.depth_test = value;
            drop(settings);
            self.bump_version();
        }
    }

    fn set_map(&self, texture: Option<TextureHandle>) {
        let matrix = {
            let mut slot = self.map.write();
            let changed = slot.texture != texture;
            slot.set_texture(texture);
            let matrix = slot.compute_matrix();
            drop(slot);
            if changed {
                self.bump_version();
            }
            matrix
        };

        let mut uniforms = self.uniforms.write();
        uniforms.map_transform = matrix;
    }
}

impl MaterialTrait for PyShaderMaterialRuntime {
    fn as_any(&self) -> &dyn std::any::Any {
        self
    }

    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }
}

impl RenderableMaterialTrait for PyShaderMaterialRuntime {
    fn shader_name(&self) -> &'static str {
        self.shader_name
    }

    fn shader_template(&self) -> Option<&'static str> {
        self.shader_source
    }

    fn shader_template_mode(&self) -> ShaderTemplateMode {
        self.shader_mode
    }

    fn version(&self) -> u64 {
        self.version.load(Ordering::Relaxed)
    }

    fn shader_defines(&self) -> ShaderDefines {
        let mut defines = ShaderDefines::new();
        self.settings.read().generate_shader_defines(&mut defines);

        let map = self.map.read();
        if map.is_some() {
            defines.set("HAS_MAP", "1");
            if map.channel != 0 {
                let uv_channel = map.channel.to_string();
                defines.set("MAP_UV", &uv_channel);
            }
        }

        defines
    }

    fn settings(&self) -> MaterialSettings {
        *self.settings.read()
    }

    fn visit_textures(&self, visitor: &mut dyn FnMut(&TextureSource)) {
        if let Some(texture) = self.map.read().texture {
            visitor(&TextureSource::Asset(texture));
        }
    }

    fn define_bindings<'a>(&'a self, builder: &mut ResourceBuilder<'a>) {
        builder.add_uniform(
            "material",
            &self.uniforms,
            wgpu::ShaderStages::VERTEX | wgpu::ShaderStages::FRAGMENT,
        );

        let map = self.map.read();
        builder.add_texture(
            "map",
            map.texture.map(TextureSource::Asset),
            wgpu::TextureSampleType::Float { filterable: true },
            wgpu::TextureViewDimension::D2,
            wgpu::ShaderStages::FRAGMENT,
        );
    }

    fn uniform_buffer(&self) -> BufferRef {
        self.uniforms.handle()
    }

    fn with_uniform_bytes(&self, f: &mut dyn FnMut(&[u8])) {
        let uniforms = self.uniforms.read();
        f(bytemuck::bytes_of(&*uniforms));
    }
}

fn with_shader_runtime(
    handle: MaterialHandle,
    f: impl FnOnce(&PyShaderMaterialRuntime),
) -> PyResult<()> {
    with_engine(|engine| {
        if let Some(material) = engine.assets.materials.get(handle)
            && let Some(runtime) = material.as_custom::<PyShaderMaterialRuntime>()
        {
            f(runtime);
        }
    })?;
    Ok(())
}

#[pyclass(name = "ShaderMaterial")]
pub struct PyShaderMaterial {
    handle: Option<MaterialHandle>,
    shader_name: &'static str,
    shader_source: Option<&'static str>,
    shader_mode: ShaderTemplateMode,
    base_color: [f32; 4],
    accent_color: [f32; 4],
    edge_color: [f32; 4],
    emissive_color: [f32; 4],
    opacity: f32,
    alpha_test: f32,
    params0: [f32; 4],
    params1: [f32; 4],
    params2: [f32; 4],
    params3: [f32; 4],
    side: Side,
    alpha_mode: AlphaMode,
    depth_write: bool,
    depth_test: bool,
    map: Option<TextureHandle>,
}

impl PyShaderMaterial {
    pub(crate) fn get_or_create_handle(&mut self) -> PyResult<MaterialHandle> {
        if let Some(handle) = self.handle {
            return Ok(handle);
        }

        let mut uniforms = default_uniforms();
        uniforms.base_color = Vec4::from_array(self.base_color);
        uniforms.accent_color = Vec4::from_array(self.accent_color);
        uniforms.edge_color = Vec4::from_array(self.edge_color);
        uniforms.emissive_color = Vec4::from_array(self.emissive_color);
        uniforms.opacity = self.opacity;
        uniforms.alpha_test = self.alpha_test;
        uniforms.params0 = Vec4::from_array(self.params0);
        uniforms.params1 = Vec4::from_array(self.params1);
        uniforms.params2 = Vec4::from_array(self.params2);
        uniforms.params3 = Vec4::from_array(self.params3);
        uniforms.map_transform = TextureSlot::from(self.map).compute_matrix();

        let settings = MaterialSettings {
            alpha_mode: self.alpha_mode,
            alpha_to_coverage: false,
            depth_write: self.depth_write,
            depth_test: self.depth_test,
            side: self.side,
        };

        let runtime = PyShaderMaterialRuntime::new(
            self.shader_name,
            self.shader_source,
            self.shader_mode,
            uniforms,
            settings,
            self.map,
        );

        let handle =
            with_engine(|engine| engine.assets.materials.add(Material::new_custom(runtime)))?;
        self.handle = Some(handle);
        Ok(handle)
    }
}

#[pymethods]
impl PyShaderMaterial {
    #[new]
    #[pyo3(signature = (
        shader_name,
        shader_source = None,
        shader_mode = "body",
        base_color = None,
        opacity = 1.0,
        side = "front",
        alpha_mode = "opaque",
        depth_write = true,
        depth_test = true,
    ))]
    #[allow(clippy::too_many_arguments)]
    fn new(
        shader_name: &str,
        shader_source: Option<&str>,
        shader_mode: &str,
        base_color: Option<&Bound<'_, PyAny>>,
        opacity: f32,
        side: &str,
        alpha_mode: &str,
        depth_write: bool,
        depth_test: bool,
    ) -> PyResult<Self> {
        let mode = parse_shader_mode(shader_mode)?;
        if shader_source.is_none() && mode != ShaderTemplateMode::Template {
            return Err(PyValueError::new_err(
                "shader_source=None only works with shader_mode='template' and a registered template name",
            ));
        }

        let base_color = match base_color {
            Some(value) => parse_color_like(value, 1.0)?,
            None => [1.0, 1.0, 1.0, 1.0],
        };

        Ok(Self {
            handle: None,
            shader_name: leak_string(shader_name),
            shader_source: shader_source.map(leak_string),
            shader_mode: mode,
            base_color,
            accent_color: [0.0, 0.0, 0.0, 0.0],
            edge_color: [0.0, 0.0, 0.0, 0.0],
            emissive_color: [0.0, 0.0, 0.0, 0.0],
            opacity,
            alpha_test: 0.0,
            params0: [0.0, 0.0, 0.0, 0.0],
            params1: [0.0, 0.0, 0.0, 0.0],
            params2: [0.0, 0.0, 0.0, 0.0],
            params3: [0.0, 0.0, 0.0, 0.0],
            side: parse_side(side)?,
            alpha_mode: parse_alpha_mode(alpha_mode)?,
            depth_write,
            depth_test,
            map: None,
        })
    }

    #[getter]
    fn get_shader_name(&self) -> &str {
        self.shader_name
    }

    #[getter]
    fn get_shader_mode(&self) -> &'static str {
        match self.shader_mode {
            ShaderTemplateMode::MaterialBody => "body",
            ShaderTemplateMode::Template => "template",
        }
    }

    #[getter]
    fn get_base_color(&self) -> [f32; 4] {
        self.base_color
    }

    #[setter]
    fn set_base_color(&mut self, value: &Bound<'_, PyAny>) -> PyResult<()> {
        self.base_color = parse_color_like(value, self.base_color[3])?;
        if let Some(handle) = self.handle {
            with_shader_runtime(handle, |runtime| runtime.set_base_color(self.base_color))?;
        }
        Ok(())
    }

    #[getter]
    fn get_accent_color(&self) -> [f32; 4] {
        self.accent_color
    }

    #[setter]
    fn set_accent_color(&mut self, value: &Bound<'_, PyAny>) -> PyResult<()> {
        self.accent_color = parse_color_like(value, self.accent_color[3])?;
        if let Some(handle) = self.handle {
            with_shader_runtime(handle, |runtime| {
                runtime.set_accent_color(self.accent_color)
            })?;
        }
        Ok(())
    }

    #[getter]
    fn get_edge_color(&self) -> [f32; 4] {
        self.edge_color
    }

    #[setter]
    fn set_edge_color(&mut self, value: &Bound<'_, PyAny>) -> PyResult<()> {
        self.edge_color = parse_color_like(value, self.edge_color[3])?;
        if let Some(handle) = self.handle {
            with_shader_runtime(handle, |runtime| runtime.set_edge_color(self.edge_color))?;
        }
        Ok(())
    }

    #[getter]
    fn get_emissive_color(&self) -> [f32; 4] {
        self.emissive_color
    }

    #[setter]
    fn set_emissive_color(&mut self, value: &Bound<'_, PyAny>) -> PyResult<()> {
        self.emissive_color = parse_color_like(value, self.emissive_color[3])?;
        if let Some(handle) = self.handle {
            with_shader_runtime(handle, |runtime| {
                runtime.set_emissive_color(self.emissive_color)
            })?;
        }
        Ok(())
    }

    #[getter]
    fn get_opacity(&self) -> f32 {
        self.opacity
    }

    #[setter]
    fn set_opacity(&mut self, value: f32) -> PyResult<()> {
        self.opacity = value;
        if let Some(handle) = self.handle {
            with_shader_runtime(handle, |runtime| runtime.set_opacity(value))?;
        }
        Ok(())
    }

    #[getter]
    fn get_alpha_test(&self) -> f32 {
        self.alpha_test
    }

    #[setter]
    fn set_alpha_test(&mut self, value: f32) -> PyResult<()> {
        self.alpha_test = value;
        if let Some(handle) = self.handle {
            with_shader_runtime(handle, |runtime| runtime.set_alpha_test(value))?;
        }
        Ok(())
    }

    #[getter]
    fn get_params0(&self) -> [f32; 4] {
        self.params0
    }

    #[setter]
    fn set_params0(&mut self, value: &Bound<'_, PyAny>) -> PyResult<()> {
        self.params0 = parse_exact_vec4(value)?;
        if let Some(handle) = self.handle {
            with_shader_runtime(handle, |runtime| runtime.set_params(0, self.params0))?;
        }
        Ok(())
    }

    #[getter]
    fn get_params1(&self) -> [f32; 4] {
        self.params1
    }

    #[setter]
    fn set_params1(&mut self, value: &Bound<'_, PyAny>) -> PyResult<()> {
        self.params1 = parse_exact_vec4(value)?;
        if let Some(handle) = self.handle {
            with_shader_runtime(handle, |runtime| runtime.set_params(1, self.params1))?;
        }
        Ok(())
    }

    #[getter]
    fn get_params2(&self) -> [f32; 4] {
        self.params2
    }

    #[setter]
    fn set_params2(&mut self, value: &Bound<'_, PyAny>) -> PyResult<()> {
        self.params2 = parse_exact_vec4(value)?;
        if let Some(handle) = self.handle {
            with_shader_runtime(handle, |runtime| runtime.set_params(2, self.params2))?;
        }
        Ok(())
    }

    #[getter]
    fn get_params3(&self) -> [f32; 4] {
        self.params3
    }

    #[setter]
    fn set_params3(&mut self, value: &Bound<'_, PyAny>) -> PyResult<()> {
        self.params3 = parse_exact_vec4(value)?;
        if let Some(handle) = self.handle {
            with_shader_runtime(handle, |runtime| runtime.set_params(3, self.params3))?;
        }
        Ok(())
    }

    #[getter]
    fn get_side(&self) -> &'static str {
        match self.side {
            Side::Front => "front",
            Side::Back => "back",
            Side::Double => "double",
        }
    }

    #[setter]
    fn set_side(&mut self, value: &str) -> PyResult<()> {
        self.side = parse_side(value)?;
        if let Some(handle) = self.handle {
            with_shader_runtime(handle, |runtime| runtime.set_side(self.side))?;
        }
        Ok(())
    }

    #[getter]
    fn get_alpha_mode(&self) -> &'static str {
        match self.alpha_mode {
            AlphaMode::Opaque => "opaque",
            AlphaMode::Mask => "mask",
            AlphaMode::Blend => "blend",
            AlphaMode::BlendMask => "blend_mask",
        }
    }

    #[setter]
    fn set_alpha_mode(&mut self, value: &str) -> PyResult<()> {
        self.alpha_mode = parse_alpha_mode(value)?;
        if let Some(handle) = self.handle {
            with_shader_runtime(handle, |runtime| runtime.set_alpha_mode(self.alpha_mode))?;
        }
        Ok(())
    }

    #[getter]
    fn get_depth_write(&self) -> bool {
        self.depth_write
    }

    #[setter]
    fn set_depth_write(&mut self, value: bool) -> PyResult<()> {
        self.depth_write = value;
        if let Some(handle) = self.handle {
            with_shader_runtime(handle, |runtime| runtime.set_depth_write(value))?;
        }
        Ok(())
    }

    #[getter]
    fn get_depth_test(&self) -> bool {
        self.depth_test
    }

    #[setter]
    fn set_depth_test(&mut self, value: bool) -> PyResult<()> {
        self.depth_test = value;
        if let Some(handle) = self.handle {
            with_shader_runtime(handle, |runtime| runtime.set_depth_test(value))?;
        }
        Ok(())
    }

    fn set_map(&mut self, texture: &PyTextureHandle) -> PyResult<()> {
        let handle = texture.inner();
        self.map = Some(handle);
        if let Some(material_handle) = self.handle {
            with_shader_runtime(material_handle, |runtime| runtime.set_map(self.map))?;
        }
        Ok(())
    }

    fn clear_map(&mut self) -> PyResult<()> {
        self.map = None;
        if let Some(material_handle) = self.handle {
            with_shader_runtime(material_handle, |runtime| runtime.set_map(None))?;
        }
        Ok(())
    }

    fn _get_handle(&mut self) -> PyResult<u64> {
        let handle = self.get_or_create_handle()?;
        use slotmap::Key;
        Ok(handle.data().as_ffi())
    }

    fn __repr__(&self) -> String {
        format!(
            "ShaderMaterial(shader='{}', mode='{}')",
            self.shader_name,
            self.get_shader_mode()
        )
    }
}

pub(crate) struct FullscreenPostPassState {
    name: &'static str,
    graph_label: &'static str,
    pass_label: &'static str,
    texture_label: &'static str,
    bind_group_label: &'static str,
    shader_name: &'static str,
    shader_source: Option<&'static str>,
    enabled: bool,
    pass: Option<&'static TemplateFullscreenPass>,
}

impl FullscreenPostPassState {
    fn new(name: &str, shader_name: &str, shader_source: Option<&str>, enabled: bool) -> Self {
        Self {
            name: leak_string(name),
            graph_label: leak_owned_string(format!("{name}_GraphPass")),
            pass_label: leak_owned_string(format!("{name} Fullscreen Pass")),
            texture_label: leak_owned_string(format!("{name}_SceneColor")),
            bind_group_label: leak_owned_string(format!("{name} BindGroup")),
            shader_name: leak_string(shader_name),
            shader_source: shader_source.map(leak_string),
            enabled,
            pass: None,
        }
    }

    fn ensure_prepared(&mut self, renderer: &mut myth_engine::Renderer) {
        if self.pass.is_some() {
            return;
        }

        let builder = RenderPassBuilder::fullscreen(self.name)
            .bind_texture_2d(0, 0, wgpu::ShaderStages::FRAGMENT, true)
            .bind_sampler(
                0,
                1,
                wgpu::ShaderStages::FRAGMENT,
                wgpu::SamplerBindingType::Filtering,
            )
            .color_target(wgpu::ColorTargetState {
                format: HDR_TEXTURE_FORMAT,
                blend: Some(wgpu::BlendState::REPLACE),
                write_mask: wgpu::ColorWrites::ALL,
            });

        let pass = match self.shader_source {
            Some(source) => builder
                .inline_shader_template(self.shader_name, source)
                .build(renderer),
            None => builder.shader_template(self.shader_name).build(renderer),
        };

        self.pass = Some(Box::leak(Box::new(pass)));
    }

    pub(crate) fn reset(&mut self) {
        self.pass = None;
    }
}

thread_local! {
    static APP_POST_PASSES: RefCell<Vec<Rc<RefCell<FullscreenPostPassState>>>> = const { RefCell::new(Vec::new()) };
}

#[pyclass(unsendable, name = "FullscreenPostPass")]
pub struct PyFullscreenPostPass {
    inner: Rc<RefCell<FullscreenPostPassState>>,
}

impl PyFullscreenPostPass {
    pub(crate) fn shared_state(&self) -> Rc<RefCell<FullscreenPostPassState>> {
        Rc::clone(&self.inner)
    }
}

#[pymethods]
impl PyFullscreenPostPass {
    #[new]
    #[pyo3(signature = (name, shader_name, shader_source = None, enabled = true))]
    fn new(name: &str, shader_name: &str, shader_source: Option<&str>, enabled: bool) -> Self {
        Self {
            inner: Rc::new(RefCell::new(FullscreenPostPassState::new(
                name,
                shader_name,
                shader_source,
                enabled,
            ))),
        }
    }

    #[getter]
    fn get_name(&self) -> String {
        self.inner.borrow().name.to_string()
    }

    #[getter]
    fn get_shader_name(&self) -> String {
        self.inner.borrow().shader_name.to_string()
    }

    #[getter]
    fn get_enabled(&self) -> bool {
        self.inner.borrow().enabled
    }

    #[setter]
    fn set_enabled(&self, value: bool) {
        self.inner.borrow_mut().enabled = value;
    }

    fn __repr__(&self) -> String {
        let state = self.inner.borrow();
        format!(
            "FullscreenPostPass(name='{}', shader='{}', enabled={})",
            state.name, state.shader_name, state.enabled
        )
    }
}

pub(crate) fn clear_app_post_passes() {
    APP_POST_PASSES.with(|cell| cell.borrow_mut().clear());
}

pub(crate) fn register_app_post_pass(pass: &PyFullscreenPostPass) {
    let shared = pass.shared_state();
    shared.borrow_mut().reset();
    APP_POST_PASSES.with(|cell| {
        let mut passes = cell.borrow_mut();
        if !passes.iter().any(|existing| Rc::ptr_eq(existing, &shared)) {
            passes.push(shared);
        }
    });
}

pub(crate) fn render_engine_with_registered_post_passes(engine: &mut Engine) {
    let passes = APP_POST_PASSES.with(|cell| cell.borrow().clone());
    render_engine_with_post_passes(engine, &passes);
}

pub(crate) fn render_engine_with_post_passes(
    engine: &mut Engine,
    post_passes: &[Rc<RefCell<FullscreenPostPassState>>],
) {
    let active_passes: Vec<_> = post_passes
        .iter()
        .filter_map(|state| {
            if state.borrow().enabled {
                Some(Rc::clone(state))
            } else {
                None
            }
        })
        .collect();

    if active_passes.is_empty() {
        engine.render_active_scene();
        return;
    }

    for state in &active_passes {
        state.borrow_mut().ensure_prepared(&mut engine.renderer);
    }

    let (width, height) = engine.renderer.size();
    let Some(mut composer) = engine.compose_frame() else {
        return;
    };

    for state in active_passes {
        composer =
            composer.add_custom_pass(HookStage::BeforePostProcess, move |rdg, blackboard| {
                let Some(scene_color) = blackboard.scene_color else {
                    return blackboard;
                };

                let borrowed = state.borrow();
                let pass = borrowed
                    .pass
                    .expect("post pass must be prepared before render");
                let graph_label = borrowed.graph_label;
                let pass_label = borrowed.pass_label;
                let texture_label = borrowed.texture_label;
                let bind_group_label = borrowed.bind_group_label;

                let new_color = rdg.add_pass(graph_label, move |builder| {
                    builder.read_texture(scene_color);
                    let out = builder.create_texture(
                        texture_label,
                        TextureDesc::new_2d(
                            width.max(1),
                            height.max(1),
                            HDR_TEXTURE_FORMAT,
                            wgpu::TextureUsages::RENDER_ATTACHMENT
                                | wgpu::TextureUsages::TEXTURE_BINDING
                                | wgpu::TextureUsages::COPY_SRC,
                        ),
                    );
                    let node = pass.build_node(
                        builder,
                        pass_label,
                        out,
                        RenderTargetOps::DontCare,
                        Some(bind_group_label),
                        |bindings| {
                            bindings.bind_texture(0, 0, scene_color);
                            bindings.bind_common_sampler(0, 1, CommonSampler::LinearClamp);
                        },
                    );
                    (node, out)
                });

                myth_engine::renderer::graph::core::GraphBlackboard {
                    scene_color: Some(new_color),
                    ..blackboard
                }
            });
    }

    composer.render();
}
