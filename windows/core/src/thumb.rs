//! The picture of a file heading to the phone.
use crate::render::Image;
use base64::Engine;
use image::imageops::{self, FilterType};
use image::{codecs::jpeg::JpegEncoder, ExtendedColorType, RgbaImage};

/// Center-crop to square, scale to 512x512, flatten on white, JPEG, base64.
pub fn square_jpeg(img: &Image) -> Option<String> {
    let rgba = RgbaImage::from_raw(img.w, img.h, img.rgba.clone())?;
    let side = img.w.min(img.h);
    if side == 0 {
        return None;
    }
    let crop = imageops::crop_imm(&rgba, (img.w - side) / 2, (img.h - side) / 2, side, side).to_image();
    let sq = imageops::resize(&crop, 512, 512, FilterType::CatmullRom);
    let mut rgb = Vec::with_capacity(512 * 512 * 3);
    for p in sq.pixels() {
        let a = p[3] as u32;
        for c in &p.0[..3] {
            rgb.push(((*c as u32 * a + 255 * (255 - a)) / 255) as u8);
        }
    }
    let mut out = Vec::new();
    JpegEncoder::new_with_quality(&mut out, 80).encode(&rgb, 512, 512, ExtendedColorType::Rgb8).ok()?;
    Some(base64::engine::general_purpose::STANDARD.encode(out))
}
