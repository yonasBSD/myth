#[cfg(feature = "gltf")]
pub mod gltf;
#[cfg(feature = "gltf")]
pub use gltf::GltfLoader;

#[cfg(feature = "3dgs")]
pub mod ply;
#[cfg(feature = "3dgs")]
pub use ply::load_gaussian_ply;

#[cfg(feature = "gaussian-npz")]
pub mod npz;
#[cfg(feature = "gaussian-npz")]
pub use npz::load_gaussian_npz;

#[cfg(feature = "gaussian-spz")]
pub mod spz;
#[cfg(feature = "gaussian-spz")]
pub use spz::load_gaussian_spz;
