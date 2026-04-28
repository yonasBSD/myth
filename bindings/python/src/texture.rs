//! TextureHandle wrapper and dynamic texture helpers.

use pyo3::prelude::*;
use pyo3::types::{PyAny, PyByteArray, PyByteArrayMethods, PyBytes, PyBytesMethods};

use crate::with_engine;

pub(crate) fn parse_color_space(color_space: &str) -> myth_engine::ColorSpace {
    match color_space {
        "linear" | "Linear" => myth_engine::ColorSpace::Linear,
        _ => myth_engine::ColorSpace::Srgb,
    }
}

pub(crate) fn with_u8_buffer<R>(
    data: &Bound<'_, PyAny>,
    f: impl FnOnce(&[u8]) -> PyResult<R>,
) -> PyResult<R> {
    if let Ok(bytes) = data.cast::<PyBytes>() {
        return f(bytes.as_bytes());
    }

    if let Ok(bytearray) = data.cast::<PyByteArray>() {
        // SAFETY: We do not execute Python code while the slice is live.
        let bytes = unsafe { bytearray.as_bytes() };
        return f(bytes);
    }

    let bytearray = PyByteArray::from(data).map_err(|_| {
        pyo3::exceptions::PyTypeError::new_err(
            "data must be bytes, bytearray, or another object implementing the Python buffer protocol"
        )
    })?;

    // SAFETY: We do not execute Python code while the slice is live.
    let bytes = unsafe { bytearray.as_bytes() };
    f(bytes)
}

pub(crate) fn create_dynamic_texture_for_engine(
    engine: &mut myth_engine::Engine,
    name: &str,
    width: u32,
    height: u32,
    data: &Bound<'_, PyAny>,
    color_space: &str,
    generate_mipmaps: bool,
) -> PyResult<PyTextureHandle> {
    let color_space = parse_color_space(color_space);
    with_u8_buffer(data, |bytes| {
        engine
            .assets
            .create_dynamic_texture(
                name,
                width,
                height,
                bytes.to_vec(),
                color_space,
                generate_mipmaps,
            )
            .map(PyTextureHandle::from_handle)
            .map_err(|e| {
                pyo3::exceptions::PyRuntimeError::new_err(format!(
                    "Failed to create dynamic texture '{name}': {e}"
                ))
            })
    })
}

pub(crate) fn update_dynamic_texture_for_engine(
    engine: &mut myth_engine::Engine,
    handle: myth_engine::TextureHandle,
    data: &Bound<'_, PyAny>,
) -> PyResult<()> {
    with_u8_buffer(data, |bytes| {
        engine
            .assets
            .update_dynamic_texture(handle, bytes)
            .map(|_| ())
            .map_err(|e| {
                pyo3::exceptions::PyRuntimeError::new_err(format!(
                    "Failed to update dynamic texture {handle:?}: {e}"
                ))
            })
    })
}

/// An opaque handle to a loaded texture.
///
/// Obtain via `ctx.load_texture()`, `ctx.load_hdr_texture()`,
/// `ctx.create_dynamic_texture()`, etc. Pass to material methods like
/// `mat.set_map(handle)`.
#[pyclass(name = "TextureHandle", skip_from_py_object)]
#[derive(Clone, Copy)]
pub struct PyTextureHandle {
    handle: myth_engine::TextureHandle,
}

impl PyTextureHandle {
    pub fn from_handle(handle: myth_engine::TextureHandle) -> Self {
        Self { handle }
    }

    pub fn inner(&self) -> myth_engine::TextureHandle {
        self.handle
    }
}

#[pymethods]
impl PyTextureHandle {
    fn __repr__(&self) -> String {
        format!("TextureHandle({:?})", self.handle)
    }

    fn __eq__(&self, other: &Self) -> bool {
        self.handle == other.handle
    }

    /// Update the bytes of a dynamic texture in place.
    ///
    /// The texture must have been created with ``Engine.create_dynamic_texture()``
    /// or ``Renderer.create_dynamic_texture()``. `data` may be any Python object
    /// exposing a C-contiguous ``uint8`` buffer, such as ``bytes``,
    /// ``bytearray``, ``memoryview``, or ``numpy.ndarray``.
    fn update_data(&self, data: &Bound<'_, PyAny>) -> PyResult<()> {
        with_engine(|engine| update_dynamic_texture_for_engine(engine, self.handle, data))?
    }
}
