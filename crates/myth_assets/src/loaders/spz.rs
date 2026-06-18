//! SPZ v4 loader for 3D Gaussian Splatting point clouds.
//!
//! SPZ stores Gaussian attributes as independently ZSTD-compressed streams.
//! This loader decodes the current v4 `NGSP` layout and converts the result
//! into Myth's GPU-ready [`GaussianCloud`] representation.

use std::io::{Read, Seek};

use glam::Vec3;
use half::f16;
use myth_core::{AssetError, Error, Result};
use myth_resources::gaussian_splat::{
    GaussianCloud, GaussianSHCoefficients, GaussianSplat, MAX_SH_DEGREE,
};
use myth_resources::image::ColorSpace;

use super::ply::{build_covariance, pack2x16float};

const NGSP_MAGIC: u32 = 0x5053_474e;
const SPZ_VERSION_V4: u32 = 4;
const HEADER_SIZE: usize = 32;
const TOC_ENTRY_SIZE: usize = 16;
const FLAG_ANTIALIASED: u8 = 0x1;
const FLAG_HAS_EXTENSIONS: u8 = 0x2;
const EXT_ADOBE_COORDINATE_SYSTEM: u32 = 0xADBE_0003;
const COORD_RUB: u32 = 4;
const COORD_RDF: u32 = 6;
const COLOR_SCALE: f32 = 0.15;
const SQRT_1_2: f32 = std::f32::consts::FRAC_1_SQRT_2;

#[derive(Debug, Clone, Copy)]
struct SpzHeader {
    num_points: usize,
    sh_degree: u32,
    fractional_bits: u8,
    flags: u8,
    num_streams: u8,
    toc_byte_offset: usize,
}

#[derive(Debug, Clone, Copy)]
struct StreamInfo {
    compressed_size: usize,
    uncompressed_size: usize,
    compressed_offset: usize,
}

#[derive(Debug, Clone, Copy)]
struct CoordinateConverter {
    flip_p: [f32; 3],
    flip_q: [f32; 3],
    flip_sh: [f32; 24],
}

impl CoordinateConverter {
    fn from_to(from: u32, to: u32) -> Result<Self> {
        if from == 0 || to == 0 || from == to {
            return Ok(Self {
                flip_p: [1.0; 3],
                flip_q: [1.0; 3],
                flip_sh: [1.0; 24],
            });
        }

        if from > 8 || to > 8 {
            return Err(Error::Asset(AssetError::Format(format!(
                "SPZ coordinate system conversion {from}->{to} is not supported yet"
            ))));
        }

        let from_bits = from - 1;
        let to_bits = to - 1;
        let x = if (from_bits & 1) == (to_bits & 1) {
            1.0
        } else {
            -1.0
        };
        let y = if (from_bits & 2) == (to_bits & 2) {
            1.0
        } else {
            -1.0
        };
        let z = if (from_bits & 4) == (to_bits & 4) {
            1.0
        } else {
            -1.0
        };

        Ok(Self {
            flip_p: [x, y, z],
            // SPZ quaternions are in xyzw order; w is left untouched.
            flip_q: [y * z, x * z, x * y],
            flip_sh: [
                y,
                z,
                x,
                x * y,
                y * z,
                1.0,
                x * z,
                1.0,
                y,
                x * y * z,
                y,
                z,
                x,
                z,
                x,
                x * y,
                y * z,
                x * y,
                y * z,
                1.0,
                x * z,
                1.0,
                x * z,
                y,
            ],
        })
    }
}

/// Loads an SPZ v4 Gaussian splat file into a [`GaussianCloud`].
///
/// The loader currently supports the v4 `NGSP` ZSTD-stream layout. Legacy
/// gzip-based v1-v3 files are rejected with a clear format error.
pub fn load_gaussian_spz<R: Read + Seek>(mut reader: R) -> Result<GaussianCloud> {
    let mut bytes = Vec::new();
    reader
        .read_to_end(&mut bytes)
        .map_err(|e| Error::Asset(AssetError::Io(e)))?;

    if bytes.starts_with(&[0x1f, 0x8b]) {
        return Err(Error::Asset(AssetError::Format(
            "legacy gzip SPZ files (v1-v3) are not supported; expected SPZ v4".into(),
        )));
    }
    if bytes.len() < HEADER_SIZE {
        return Err(Error::Asset(AssetError::Format(
            "SPZ file is smaller than the v4 header".into(),
        )));
    }

    let header = parse_header(&bytes[..HEADER_SIZE])?;
    let storage_coord = if (header.flags & FLAG_HAS_EXTENSIONS) != 0 {
        parse_storage_coordinate_system(&bytes, header.toc_byte_offset)?
    } else {
        COORD_RUB
    };
    let converter = CoordinateConverter::from_to(storage_coord, COORD_RDF)?;

    let streams = decompress_streams(&bytes, &header)?;
    build_cloud(&header, &streams, &converter)
}

fn parse_header(bytes: &[u8]) -> Result<SpzHeader> {
    let magic = u32::from_le_bytes(bytes[0..4].try_into().unwrap());
    if magic != NGSP_MAGIC {
        return Err(Error::Asset(AssetError::Format(
            "not an SPZ v4 file: missing NGSP magic".into(),
        )));
    }

    let version = u32::from_le_bytes(bytes[4..8].try_into().unwrap());
    if version != SPZ_VERSION_V4 {
        return Err(Error::Asset(AssetError::Format(format!(
            "unsupported SPZ version {version}; only v4 is supported"
        ))));
    }

    let num_points = u32::from_le_bytes(bytes[8..12].try_into().unwrap()) as usize;
    let sh_degree = u32::from(bytes[12]);
    if sh_degree > 4 {
        return Err(Error::Asset(AssetError::Format(format!(
            "unsupported SPZ SH degree {sh_degree}"
        ))));
    }
    if bytes[13] >= 31 {
        return Err(Error::Asset(AssetError::Format(format!(
            "unsupported SPZ fractional bits value {}",
            bytes[13]
        ))));
    }

    let num_streams = bytes[15];
    let toc_byte_offset = u32::from_le_bytes(bytes[16..20].try_into().unwrap()) as usize;
    if toc_byte_offset < HEADER_SIZE {
        return Err(Error::Asset(AssetError::Format(
            "SPZ TOC offset points inside the fixed header".into(),
        )));
    }
    if bytes[20..32].iter().any(|&b| b != 0) {
        return Err(Error::Asset(AssetError::Format(
            "SPZ reserved header bytes must be zero".into(),
        )));
    }

    Ok(SpzHeader {
        num_points,
        sh_degree,
        fractional_bits: bytes[13],
        flags: bytes[14],
        num_streams,
        toc_byte_offset,
    })
}

fn parse_storage_coordinate_system(bytes: &[u8], toc_byte_offset: usize) -> Result<u32> {
    if toc_byte_offset > bytes.len() {
        return Err(Error::Asset(AssetError::Format(
            "SPZ TOC offset is past the end of the file".into(),
        )));
    }

    let mut offset = HEADER_SIZE;
    let mut coord = COORD_RUB;
    while offset < toc_byte_offset {
        if toc_byte_offset - offset < 8 {
            return Err(Error::Asset(AssetError::Format(
                "truncated SPZ extension record header".into(),
            )));
        }
        let ext_type = u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap());
        let payload_len =
            u32::from_le_bytes(bytes[offset + 4..offset + 8].try_into().unwrap()) as usize;
        offset += 8;
        let payload_end = offset.checked_add(payload_len).ok_or_else(|| {
            Error::Asset(AssetError::InvalidData(
                "SPZ extension payload length overflow".into(),
            ))
        })?;
        if payload_end > toc_byte_offset {
            return Err(Error::Asset(AssetError::Format(
                "SPZ extension payload extends into the TOC".into(),
            )));
        }
        if ext_type == EXT_ADOBE_COORDINATE_SYSTEM {
            if payload_len != 4 {
                return Err(Error::Asset(AssetError::Format(
                    "SPZ Adobe coordinate-system extension must be 4 bytes".into(),
                )));
            }
            let value = u32::from_le_bytes(bytes[offset..offset + 4].try_into().unwrap());
            if (1..=16).contains(&value) {
                coord = value;
            }
        }
        offset = payload_end;
    }

    Ok(coord)
}

fn decompress_streams(bytes: &[u8], header: &SpzHeader) -> Result<Vec<Vec<u8>>> {
    let toc_size = usize::from(header.num_streams)
        .checked_mul(TOC_ENTRY_SIZE)
        .ok_or_else(|| Error::Asset(AssetError::InvalidData("SPZ TOC size overflow".into())))?;
    let toc_end = header
        .toc_byte_offset
        .checked_add(toc_size)
        .ok_or_else(|| Error::Asset(AssetError::InvalidData("SPZ TOC end overflow".into())))?;
    if toc_end > bytes.len() {
        return Err(Error::Asset(AssetError::Format(
            "SPZ TOC extends past the end of the file".into(),
        )));
    }

    let expected_sizes = expected_stream_sizes(header)?;
    if expected_sizes.len() != usize::from(header.num_streams) {
        return Err(Error::Asset(AssetError::Format(format!(
            "SPZ stream count mismatch: header has {}, expected {}",
            header.num_streams,
            expected_sizes.len()
        ))));
    }

    let mut infos = Vec::with_capacity(usize::from(header.num_streams));
    let mut compressed_offset = toc_end;
    for i in 0..usize::from(header.num_streams) {
        let toc_entry = header.toc_byte_offset + i * TOC_ENTRY_SIZE;
        let compressed_size =
            u64::from_le_bytes(bytes[toc_entry..toc_entry + 8].try_into().unwrap()) as usize;
        let uncompressed_size =
            u64::from_le_bytes(bytes[toc_entry + 8..toc_entry + 16].try_into().unwrap()) as usize;
        if uncompressed_size != expected_sizes[i] {
            return Err(Error::Asset(AssetError::Format(format!(
                "SPZ stream {i} has uncompressed size {uncompressed_size}, expected {}",
                expected_sizes[i]
            ))));
        }
        let end = compressed_offset
            .checked_add(compressed_size)
            .ok_or_else(|| {
                Error::Asset(AssetError::InvalidData(
                    "SPZ compressed stream offset overflow".into(),
                ))
            })?;
        if end > bytes.len() {
            return Err(Error::Asset(AssetError::Format(
                "SPZ compressed stream extends past end of file".into(),
            )));
        }
        infos.push(StreamInfo {
            compressed_size,
            uncompressed_size,
            compressed_offset,
        });
        compressed_offset = end;
    }

    if compressed_offset != bytes.len() {
        return Err(Error::Asset(AssetError::Format(
            "SPZ file has trailing bytes after compressed streams".into(),
        )));
    }

    infos
        .iter()
        .enumerate()
        .map(|(i, info)| {
            zstd::bulk::decompress(
                &bytes[info.compressed_offset..info.compressed_offset + info.compressed_size],
                info.uncompressed_size,
            )
            .map_err(|e| {
                Error::Asset(AssetError::Format(format!(
                    "failed to decompress SPZ stream {i}: {e}"
                )))
            })
            .and_then(|decoded| {
                if decoded.len() == info.uncompressed_size {
                    Ok(decoded)
                } else {
                    Err(Error::Asset(AssetError::Format(format!(
                        "SPZ stream {i} decompressed to {} bytes, expected {}",
                        decoded.len(),
                        info.uncompressed_size
                    ))))
                }
            })
        })
        .collect()
}

fn expected_stream_sizes(header: &SpzHeader) -> Result<Vec<usize>> {
    let n = header.num_points;
    let sh_dim = sh_dim_for_degree(header.sh_degree)?;
    let mut sizes = vec![
        n.checked_mul(9).ok_or_else(|| {
            Error::Asset(AssetError::InvalidData(
                "SPZ positions stream size overflow".into(),
            ))
        })?,
        n,
        n.checked_mul(3)
            .ok_or_else(|| Error::Asset(AssetError::InvalidData("SPZ colors overflow".into())))?,
        n.checked_mul(3)
            .ok_or_else(|| Error::Asset(AssetError::InvalidData("SPZ scales overflow".into())))?,
        n.checked_mul(4).ok_or_else(|| {
            Error::Asset(AssetError::InvalidData(
                "SPZ rotations stream size overflow".into(),
            ))
        })?,
    ];
    let sh_size = n
        .checked_mul(sh_dim)
        .and_then(|v| v.checked_mul(3))
        .ok_or_else(|| Error::Asset(AssetError::InvalidData("SPZ SH stream overflow".into())))?;
    if sh_size > 0 {
        sizes.push(sh_size);
    }
    Ok(sizes)
}

fn build_cloud(
    header: &SpzHeader,
    streams: &[Vec<u8>],
    converter: &CoordinateConverter,
) -> Result<GaussianCloud> {
    let positions = &streams[0];
    let alphas = &streams[1];
    let colors = &streams[2];
    let scales = &streams[3];
    let rotations = &streams[4];
    let sh = streams.get(5).map(Vec::as_slice).unwrap_or(&[]);

    let n = header.num_points;
    let source_sh_dim = sh_dim_for_degree(header.sh_degree)?;
    let myth_sh_degree = header.sh_degree.min(MAX_SH_DEGREE);
    let myth_coeff_count = coeff_count_for_degree(myth_sh_degree);
    let source_rest_to_copy = source_sh_dim.min(myth_coeff_count.saturating_sub(1));

    let mut gaussians = Vec::with_capacity(n);
    let mut sh_coefficients = Vec::with_capacity(n);
    let mut aabb_min = Vec3::splat(f32::INFINITY);
    let mut aabb_max = Vec3::splat(f32::NEG_INFINITY);
    let position_scale = 1.0 / ((1u32 << u32::from(header.fractional_bits)) as f32);

    for i in 0..n {
        let position_base = i * 9;
        let mut pos = [
            decode_fixed24(&positions[position_base..position_base + 3])? * position_scale,
            decode_fixed24(&positions[position_base + 3..position_base + 6])? * position_scale,
            decode_fixed24(&positions[position_base + 6..position_base + 9])? * position_scale,
        ];
        for (value, flip) in pos.iter_mut().zip(converter.flip_p) {
            *value *= flip;
        }
        let pos_vec = Vec3::new(pos[0], pos[1], pos[2]);
        aabb_min = aabb_min.min(pos_vec);
        aabb_max = aabb_max.max(pos_vec);

        let scale_base = i * 3;
        let scale = [
            (f32::from(scales[scale_base]) / 16.0 - 10.0).exp(),
            (f32::from(scales[scale_base + 1]) / 16.0 - 10.0).exp(),
            (f32::from(scales[scale_base + 2]) / 16.0 - 10.0).exp(),
        ];

        let rotation_base = i * 4;
        let mut rotation_xyzw = unpack_quaternion_smallest_three(
            rotations[rotation_base..rotation_base + 4]
                .try_into()
                .unwrap(),
        );
        for (value, flip) in rotation_xyzw[..3].iter_mut().zip(converter.flip_q) {
            *value *= flip;
        }
        let q_wxyz = [
            rotation_xyzw[3],
            rotation_xyzw[0],
            rotation_xyzw[1],
            rotation_xyzw[2],
        ];
        let cov = build_covariance(q_wxyz, scale);
        let packed_cov = [
            pack2x16float(cov[0], cov[1]),
            pack2x16float(cov[2], cov[3]),
            pack2x16float(cov[4], cov[5]),
        ];

        let opacity = f32::from(alphas[i]) / 255.0;
        gaussians.push(GaussianSplat {
            x: pos[0],
            y: pos[1],
            z: pos[2],
            opacity: pack2x16float(opacity, 0.0),
            sh_idx: i as u32,
            cov: packed_cov,
        });

        let mut sh_flat = [[0.0f32; 3]; 16];
        let color_base = i * 3;
        sh_flat[0] = [
            decode_color(colors[color_base]),
            decode_color(colors[color_base + 1]),
            decode_color(colors[color_base + 2]),
        ];

        let sh_base = i * source_sh_dim * 3;
        for coeff in 0..source_rest_to_copy {
            let base = sh_base + coeff * 3;
            let flip = converter.flip_sh[coeff];
            sh_flat[coeff + 1] = [
                unquantize_sh(sh[base]) * flip,
                unquantize_sh(sh[base + 1]) * flip,
                unquantize_sh(sh[base + 2]) * flip,
            ];
        }

        sh_coefficients.push(GaussianSHCoefficients {
            data: pack_sh_coefficients(&sh_flat),
        });
    }

    if n == 0 {
        aabb_min = Vec3::ZERO;
        aabb_max = Vec3::ZERO;
    }

    let center = if n == 0 {
        Vec3::ZERO
    } else {
        (aabb_min + aabb_max) * 0.5
    };

    Ok(GaussianCloud {
        gaussians,
        sh_coefficients,
        sh_degree: myth_sh_degree,
        num_points: n,
        aabb_min,
        aabb_max,
        center,
        mip_splatting: (header.flags & FLAG_ANTIALIASED) != 0,
        kernel_size: 0.3,
        color_space: ColorSpace::Srgb,
        opacity_compensation: 1.0,
    })
}

fn decode_fixed24(bytes: &[u8]) -> Result<f32> {
    if bytes.len() != 3 {
        return Err(Error::Asset(AssetError::Format(
            "SPZ fixed-point component must be 3 bytes".into(),
        )));
    }
    let mut value = i32::from(bytes[0]) | (i32::from(bytes[1]) << 8) | (i32::from(bytes[2]) << 16);
    if (value & 0x80_0000) != 0 {
        value |= !0xFF_FFFF;
    }
    Ok(value as f32)
}

fn unpack_quaternion_smallest_three(bytes: [u8; 4]) -> [f32; 4] {
    let mut packed = u32::from_le_bytes(bytes);
    let largest = (packed >> 30) as usize;
    let mut q = [0.0f32; 4];
    let mut sum_squares = 0.0;
    for i in (0..4).rev() {
        if i == largest {
            continue;
        }
        let mag = packed & 0x1ff;
        let neg = ((packed >> 9) & 0x1) != 0;
        packed >>= 10;
        let value = SQRT_1_2 * (mag as f32) / 511.0;
        q[i] = if neg { -value } else { value };
        sum_squares += q[i] * q[i];
    }
    q[largest] = (1.0 - sum_squares).max(0.0).sqrt();
    q
}

#[inline]
fn decode_color(value: u8) -> f32 {
    ((f32::from(value) / 255.0) - 0.5) / COLOR_SCALE
}

#[inline]
fn unquantize_sh(value: u8) -> f32 {
    (f32::from(value) - 128.0) / 128.0
}

fn pack_sh_coefficients(coefficients: &[[f32; 3]; 16]) -> [u32; 24] {
    let mut packed = [0u32; 24];
    for (coeff_idx, coeff) in coefficients.iter().enumerate() {
        for (ch, value) in coeff.iter().enumerate() {
            let half_idx = coeff_idx * 3 + ch;
            let u32_idx = half_idx / 2;
            let sub_idx = half_idx % 2;
            let half = f16::from_f32(*value).to_bits();
            packed[u32_idx] |= (half as u32) << (sub_idx * 16);
        }
    }
    packed
}

fn sh_dim_for_degree(degree: u32) -> Result<usize> {
    match degree {
        0 => Ok(0),
        1 => Ok(3),
        2 => Ok(8),
        3 => Ok(15),
        4 => Ok(24),
        _ => Err(Error::Asset(AssetError::Format(format!(
            "unsupported SH degree {degree}"
        )))),
    }
}

fn coeff_count_for_degree(degree: u32) -> usize {
    ((degree + 1) * (degree + 1)) as usize
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn fixed24_sign_extends() {
        assert_eq!(decode_fixed24(&[0xff, 0xff, 0xff]).unwrap(), -1.0);
        assert_eq!(decode_fixed24(&[0x00, 0x00, 0x80]).unwrap(), -8_388_608.0);
        assert_eq!(decode_fixed24(&[0xff, 0xff, 0x7f]).unwrap(), 8_388_607.0);
    }

    #[test]
    fn rub_to_rdf_flips_expected_axes() {
        let converter = CoordinateConverter::from_to(COORD_RUB, COORD_RDF).unwrap();
        assert_eq!(converter.flip_p, [1.0, -1.0, -1.0]);
        assert_eq!(converter.flip_q, [1.0, -1.0, -1.0]);
        assert_eq!(converter.flip_sh[0..3], [-1.0, -1.0, 1.0]);
    }

    #[test]
    #[ignore = "set MYTH_SPZ_TEST_ASSET to a local .spz file to run"]
    fn loads_external_spz_asset() {
        let path = std::env::var("MYTH_SPZ_TEST_ASSET").expect("MYTH_SPZ_TEST_ASSET must be set");
        let file = std::fs::File::open(&path).unwrap();
        let cloud = load_gaussian_spz(file).unwrap();
        assert!(cloud.num_points > 0);
        assert_eq!(cloud.gaussians.len(), cloud.num_points);
        assert_eq!(cloud.sh_coefficients.len(), cloud.num_points);
        assert!(cloud.aabb_min.cmple(cloud.aabb_max).all());
    }
}
