//! Pixels for a layered window: premultiplied BGRA in `u32`s, drawn on the CPU so the exact same frames can be
//! looked at on any OS. `Canvas` wraps the window's bitmap; only the rectangles that change are touched.
use crate::server::Edge;
use crate::stage::{Glass, Glow, TilePose};
use base64::Engine;
use image::imageops::{self, FilterType};
use image::RgbaImage;

#[derive(Clone, PartialEq)]
pub struct Image {
    pub w: u32,
    pub h: u32,
    pub rgba: Vec<u8>,
}

impl std::fmt::Debug for Image {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "Image({}x{})", self.w, self.h)
    }
}

pub fn decode(bytes: &[u8]) -> Option<Image> {
    let i = image::load_from_memory(bytes).ok()?.to_rgba8();
    Some(Image { w: i.width(), h: i.height(), rgba: i.into_raw() })
}

pub fn decode_b64(s: &str) -> Option<Image> {
    decode(&base64::engine::general_purpose::STANDARD.decode(s).ok()?)
}

/// Coverage of a line of text, from the OS's own font: 8-bit alpha, `w`×`h`.
pub struct Mask {
    pub w: usize,
    pub h: usize,
    pub a: Vec<u8>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Default)]
pub struct Rect {
    pub x0: i32,
    pub y0: i32,
    pub x1: i32,
    pub y1: i32,
}

impl Rect {
    pub fn empty(&self) -> bool {
        self.x1 <= self.x0 || self.y1 <= self.y0
    }

    pub fn union(self, o: Rect) -> Rect {
        if self.empty() {
            return o;
        }
        if o.empty() {
            return self;
        }
        Rect { x0: self.x0.min(o.x0), y0: self.y0.min(o.y0), x1: self.x1.max(o.x1), y1: self.y1.max(o.y1) }
    }
}

pub struct Canvas<'a> {
    pub w: usize,
    pub h: usize,
    pub px: &'a mut [u32],
}

impl Canvas<'_> {
    fn clip(&self, x0: f64, y0: f64, x1: f64, y1: f64) -> Rect {
        Rect {
            x0: x0.floor().max(0.0) as i32,
            y0: y0.floor().max(0.0) as i32,
            x1: x1.ceil().min(self.w as f64) as i32,
            y1: y1.ceil().min(self.h as f64) as i32,
        }
    }

    pub fn clear(&mut self, r: Rect) {
        if r.empty() {
            return;
        }
        for y in r.y0..r.y1 {
            let s = y as usize * self.w;
            self.px[s + r.x0 as usize..s + r.x1 as usize].fill(0);
        }
    }

    /// Draws `s` with its middle at the pose's centre. The canvas under it is expected to be clear.
    pub fn sprite(&mut self, s: &Sprite, p: &TilePose) -> Rect {
        let (sw, sh) = (s.w as f64, s.h as f64);
        let alpha = (p.alpha.clamp(0.0, 1.0) * 256.0) as u32;
        if p.rot == 0.0 && p.scale == 1.0 {
            let (x0, y0) = ((p.cx - sw / 2.0).round() as i32, (p.cy - sh / 2.0).round() as i32);
            let r = Rect { x0: x0.max(0), y0: y0.max(0), x1: (x0 + s.w as i32).min(self.w as i32), y1: (y0 + s.h as i32).min(self.h as i32) };
            if r.empty() {
                return Rect::default();
            }
            let n = (r.x1 - r.x0) as usize;
            for y in r.y0..r.y1 {
                let from = (y - y0) as usize * s.w + (r.x0 - x0) as usize;
                let to = y as usize * self.w + r.x0 as usize;
                let (src, dst) = (&s.px[from..from + n], &mut self.px[to..to + n]);
                if alpha >= 256 {
                    dst.copy_from_slice(src);
                } else {
                    dst.iter_mut().zip(src).for_each(|(d, c)| *d = scale_px(*c, alpha));
                }
            }
            return r;
        }
        let (sin, cos) = p.rot.sin_cos();
        let half = (sw * sw + sh * sh).sqrt() / 2.0 * p.scale + 1.0;
        let r = self.clip(p.cx - half, p.cy - half, p.cx + half, p.cy + half);
        if r.empty() {
            return Rect::default();
        }
        let inv = 1.0 / p.scale.max(1e-3);
        for y in r.y0..r.y1 {
            let dy = y as f64 + 0.5 - p.cy;
            let row = y as usize * self.w;
            for x in r.x0..r.x1 {
                let dx = x as f64 + 0.5 - p.cx;
                let u = (dx * cos + dy * sin) * inv + sw / 2.0 - 0.5;
                let v = (dy * cos - dx * sin) * inv + sh / 2.0 - 0.5;
                if u <= -1.0 || v <= -1.0 || u >= sw || v >= sh {
                    continue;
                }
                self.px[row + x as usize] = scale_px(s.bilinear(u, v), alpha);
            }
        }
        r
    }

    /// The connect ceremony: `GlassFX`'s fragment shader, row by row, skipping the empty middle of the wave.
    pub fn glass(&mut self, g: &Glass) -> Rect {
        let ppm = 1.0 / g.mm_per_px;
        let lens = if g.men > 0.0 { g.men + 0.5 } else { 0.0 };
        let (band, width) = if g.front >= 0.0 {
            let w = 2.5 + 0.05 * g.front;
            (3.0 * w * 0.7, w * 0.7)
        } else {
            (0.0, 1.0)
        };
        let outer = lens.max(if g.front >= 0.0 { g.front + band } else { 0.0 });
        let inner = if g.front >= 0.0 { (g.front - band).max(lens) } else { outer };
        if outer <= 0.0 {
            return Rect::default();
        }
        let (sx, sy) = g.seam;
        let r = self.clip(sx - outer * ppm, sy - outer * ppm, sx + outer * ppm, sy + outer * ppm);
        if r.empty() {
            return Rect::default();
        }
        let light_dir = normalize([-0.42, -0.62, 0.66]);
        for y in r.y0..r.y1 {
            let qy = (y as f64 + 0.5 - sy) * g.mm_per_px;
            let reach = |rad: f64| {
                let c = rad * rad - qy * qy;
                if c > 0.0 { c.sqrt() * ppm } else { -1.0 }
            };
            let out = reach(outer);
            if out < 0.0 {
                continue;
            }
            let hole = reach(inner); // nothing between the lens and the rim
            let row = y as usize * self.w;
            let span = |a: f64, b: f64, this: &mut Self| {
                let (x0, x1) = ((a.floor() as i32).max(r.x0), (b.ceil() as i32).min(r.x1));
                for x in x0..x1 {
                    let qx = (x as f64 + 0.5 - sx) * g.mm_per_px;
                    this.px[row + x as usize] = glass_px(qx, qy, g, width, light_dir);
                }
            };
            if hole > 0.0 && inner < outer {
                span(sx - out, sx - hole, self);
                span(sx + hole, sx + out, self);
            } else {
                span(sx - out, sx + out, self);
            }
        }
        r
    }

    /// A soft pool of light where the cursor meets the edge.
    pub fn glow(&mut self, g: &Glow) -> Rect {
        let r = self.clip(g.at.0 - g.radius * 2.0, g.at.1 - g.radius * 2.0, g.at.0 + g.radius * 2.0, g.at.1 + g.radius * 2.0);
        if r.empty() || g.strength <= 0.0 {
            return Rect::default();
        }
        for y in r.y0..r.y1 {
            let dy = (y as f64 + 0.5 - g.at.1) / g.radius;
            let row = y as usize * self.w;
            for x in r.x0..r.x1 {
                let dx = (x as f64 + 0.5 - g.at.0) / g.radius;
                let l = g.strength * (-(dx * dx + dy * dy) * 1.6).exp();
                let d = &mut self.px[row + x as usize];
                *d = add_px(*d, l * 0.92, l * 0.95, l, l * 0.7);
            }
        }
        r
    }
}

fn normalize(v: [f64; 3]) -> [f64; 3] {
    let l = (v[0] * v[0] + v[1] * v[1] + v[2] * v[2]).sqrt();
    [v[0] / l, v[1] / l, v[2] / l]
}

fn glass_px(qx: f64, qy: f64, g: &Glass, width: f64, sun: [f64; 3]) -> u32 {
    let d = (qx * qx + qy * qy).sqrt();
    let (mut light, mut cover) = (0.0, 0.0);
    if g.men > 0.0 {
        let t = ((d - g.men + 0.4) / 0.8).clamp(0.0, 1.0);
        let mask = 1.0 - t * t * (3.0 - 2.0 * t);
        if mask > 0.0 {
            let (nx, ny) = (qx / g.men, qy / g.men);
            let z = (1.0 - nx * nx - ny * ny).max(0.0).sqrt();
            let fres = (1.0 - z).powi(3);
            let s = (nx * sun[0] + ny * sun[1] + z * sun[2]).max(0.0);
            light = mask * (0.03 + 0.42 * fres + 0.75 * s.powi(70) + 0.1 * s.powi(6));
            cover = mask * (0.08 + 0.3 * fres);
        }
    }
    if g.front >= 0.0 {
        let x = (d - g.front) / width;
        let rim = (-x * x).exp() * g.fade;
        light += rim * 0.42;
        cover = f64::max(cover, rim * 0.42);
    }
    pack(light * 0.92, light * 0.95, light, cover)
}

#[inline]
fn pack(r: f64, g: f64, b: f64, a: f64) -> u32 {
    let c = |v: f64| (v.clamp(0.0, 1.0) * 255.0 + 0.5) as u32;
    c(a) << 24 | c(r) << 16 | c(g) << 8 | c(b)
}

#[inline]
fn add_px(d: u32, r: f64, g: f64, b: f64, a: f64) -> u32 {
    let c = |v: f64, shift: u32| ((d >> shift & 255) + (v.clamp(0.0, 1.0) * 255.0 + 0.5) as u32).min(255) << shift;
    c(a, 24) | c(r, 16) | c(g, 8) | c(b, 0)
}

#[inline]
fn scale_px(c: u32, alpha: u32) -> u32 {
    if alpha >= 256 {
        return c;
    }
    let rb = (c & 0x00ff_00ff).wrapping_mul(alpha) >> 8 & 0x00ff_00ff;
    let ag = (c >> 8 & 0x00ff_00ff).wrapping_mul(alpha) & 0xff00_ff00;
    rb | ag
}

/// The tile, finished once per drag: picture, rounded corners, stack, badge and shadow.
pub struct Sprite {
    pub w: usize,
    pub h: usize,
    pub px: Vec<u32>,
}

impl Sprite {
    fn at(&self, x: isize, y: isize) -> u32 {
        if x < 0 || y < 0 || x >= self.w as isize || y >= self.h as isize {
            return 0;
        }
        self.px[y as usize * self.w + x as usize]
    }

    fn bilinear(&self, u: f64, v: f64) -> u32 {
        let (x, y) = (u.floor(), v.floor());
        let (fx, fy) = (((u - x) * 256.0) as u32, ((v - y) * 256.0) as u32);
        let (x, y) = (x as isize, y as isize);
        let mix = |a: u32, b: u32, t: u32| {
            let rb = ((a & 0x00ff_00ff) * (256 - t) + (b & 0x00ff_00ff) * t) >> 8 & 0x00ff_00ff;
            let ag = ((a >> 8 & 0x00ff_00ff) * (256 - t) + (b >> 8 & 0x00ff_00ff) * t) & 0xff00_ff00;
            rb | ag
        };
        mix(mix(self.at(x, y), self.at(x + 1, y), fx), mix(self.at(x, y + 1), self.at(x + 1, y + 1), fx), fy)
    }
}

/// Signed distance to a box with continuous (squircle-like) corners, like the Mac's `cornerCurve`.
fn round_box(x: f64, y: f64, hw: f64, hh: f64, r: f64) -> f64 {
    let r = r.min(hw).min(hh);
    let k = r * 1.3;
    let (qx, qy) = (x.abs() - hw + k, y.abs() - hh + k);
    if qx <= 0.0 || qy <= 0.0 {
        return qx.max(qy) - k;
    }
    const N: f64 = 2.6;
    (qx.powf(N) + qy.powf(N)).powf(1.0 / N) - k
}

#[inline]
fn over(d: &mut [f32; 4], c: [f32; 3], a: f32) {
    let k = 1.0 - a;
    for i in 0..3 {
        d[i] = d[i] * k + c[i] * a;
    }
    d[3] = d[3] * k + a;
}

fn blur3(a: &mut [f32], w: usize, h: usize, radius: usize) {
    if radius == 0 {
        return;
    }
    let mut tmp = vec![0f32; a.len()];
    let box1 = |src: &[f32], dst: &mut [f32], n: usize, step: usize, lines: usize, line: usize| {
        let div = (radius * 2 + 1) as f32;
        for l in 0..lines {
            let base = l * line;
            let mut sum = src[base] * (radius as f32 + 1.0);
            for i in 1..=radius {
                sum += src[base + i.min(n - 1) * step];
            }
            for i in 0..n {
                dst[base + i * step] = sum / div;
                sum += src[base + (i + radius + 1).min(n - 1) * step] - src[base + i.saturating_sub(radius) * step];
            }
        }
    };
    for _ in 0..3 {
        box1(a, &mut tmp, w, 1, h, w);
        box1(&tmp, a, h, w, w, 1);
    }
}

/// `tile` px square, picture in its own shape inside it. `badge_right`: the count sits on the corner that shows first.
pub fn build_sprite(image: Option<&Image>, tile: f64, scale: f64, count: usize, badge_right: bool, text: Option<&Mask>) -> Sprite {
    let t = tile.round().max(1.0);
    let aspect = image.map_or(1.0, |i| i.w as f64 / (i.h as f64).max(1.0));
    let (iw, ih) = if aspect >= 1.0 { (t, (t / aspect).round().max(1.0)) } else { ((t * aspect).round().max(1.0), t) };
    let sigma = 6.0 * scale;
    let badge = (26.0 * scale).max(t * 0.3);
    let margin = ((sigma * 3.0 + 4.0 * scale).max(t * 0.2).max(badge * 0.3)).ceil() + 2.0;
    let (w, h) = ((t + margin * 2.0) as usize, (t + margin * 2.0) as usize);
    let (cx, cy) = (w as f64 / 2.0, h as f64 / 2.0);
    let mut layer = vec![[0f32; 4]; w * h];
    let mut shape = vec![0f32; w * h];

    if count > 1 {
        for (deg, grey) in [(-6.0f64, 0.8f32), (7.0, 0.92)] {
            let (s, c) = deg.to_radians().sin_cos();
            for y in 0..h {
                for x in 0..w {
                    let (dx, dy) = (x as f64 + 0.5 - cx, y as f64 + 0.5 - cy);
                    let d = round_box(dx * c + dy * s, dy * c - dx * s, t / 2.0, t / 2.0, t * 0.2);
                    let a = (0.5 - d).clamp(0.0, 1.0) as f32;
                    if a > 0.0 {
                        let edge = ((d + 1.5).clamp(0.0, 1.0) * 0.6) as f32; // a thin grey line around the card
                        let v = grey * (1.0 - edge) + 0.55 * edge;
                        over(&mut layer[y * w + x], [v, v, v], a);
                        shape[y * w + x] = shape[y * w + x].max(a);
                    }
                }
            }
        }
    }

    let pic = image.and_then(|i| RgbaImage::from_raw(i.w, i.h, i.rgba.clone()))
        .map(|p| imageops::resize(&p, iw as u32, ih as u32, FilterType::CatmullRom));
    let radius = t * 0.09;
    let (x0, y0) = (cx - iw / 2.0, cy - ih / 2.0);
    for y in 0..h {
        for x in 0..w {
            let (dx, dy) = (x as f64 + 0.5 - cx, y as f64 + 0.5 - cy);
            let a = (0.5 - round_box(dx, dy, iw / 2.0, ih / 2.0, radius)).clamp(0.0, 1.0) as f32;
            if a <= 0.0 {
                continue;
            }
            let (u, v) = (((x as f64 + 0.5 - x0) as u32).min(iw as u32 - 1), ((y as f64 + 0.5 - y0) as u32).min(ih as u32 - 1));
            let c = pic.as_ref().map_or([0.5, 0.5, 0.5], |p| {
                let q = p.get_pixel(u, v);
                [q[0] as f32 / 255.0, q[1] as f32 / 255.0, q[2] as f32 / 255.0]
            });
            over(&mut layer[y * w + x], c, a);
            shape[y * w + x] = shape[y * w + x].max(a);
        }
    }

    if count > 1 {
        let left = cx - t / 2.0;
        let bx = if badge_right { left + t - badge * 0.7 } else { left - badge * 0.3 } + badge / 2.0;
        let by = cy - t / 2.0 - badge * 0.3 + badge / 2.0;
        for y in 0..h {
            for x in 0..w {
                let d = ((x as f64 + 0.5 - bx).powi(2) + (y as f64 + 0.5 - by).powi(2)).sqrt() - badge / 2.0;
                let a = (0.5 - d).clamp(0.0, 1.0) as f32;
                if a > 0.0 {
                    over(&mut layer[y * w + x], [1.0, 0.231, 0.188], a);
                    shape[y * w + x] = shape[y * w + x].max(a);
                }
            }
        }
        if let Some(m) = text {
            let (mx, my) = ((bx - m.w as f64 / 2.0).round() as isize, (by - m.h as f64 / 2.0).round() as isize);
            for j in 0..m.h {
                for i in 0..m.w {
                    let (x, y) = (mx + i as isize, my + j as isize);
                    if x >= 0 && y >= 0 && (x as usize) < w && (y as usize) < h {
                        over(&mut layer[y as usize * w + x as usize], [1.0, 1.0, 1.0], m.a[j * m.w + i] as f32 / 255.0);
                    }
                }
            }
        }
    }

    blur3(&mut shape, w, h, (sigma * 0.8).round() as usize); // three box passes of radius r: sigma ≈ 1.25 r
    let drop = (4.0 * scale).round() as usize;
    let mut px = vec![0u32; w * h];
    for y in 0..h {
        for x in 0..w {
            let s = if y >= drop { shape[(y - drop) * w + x] * 0.4 } else { 0.0 };
            let [r, g, b, a] = layer[y * w + x];
            let k = 1.0 - a;
            let out = a + s * k;
            px[y * w + x] = pack(r as f64, g as f64, b as f64, out as f64);
        }
    }
    Sprite { w, h, px }
}

/// The tray glyph: a ring while nothing is connected, a disc while a phone is. Straight-alpha BGRA.
pub fn tray_glyph(size: usize, connected: bool, rgb: [u8; 3]) -> Vec<u8> {
    let mut out = vec![0u8; size * size * 4];
    let c = size as f64 / 2.0;
    let (outer, inner) = (size as f64 * 0.34, size as f64 * 0.22);
    for y in 0..size {
        for x in 0..size {
            let d = ((x as f64 + 0.5 - c).powi(2) + (y as f64 + 0.5 - c).powi(2)).sqrt();
            let mut a = (outer + 0.5 - d).clamp(0.0, 1.0);
            if !connected {
                a *= (d - inner + 0.5).clamp(0.0, 1.0);
            }
            let p = &mut out[(y * size + x) * 4..][..4];
            p.copy_from_slice(&[rgb[2], rgb[1], rgb[0], (a * 255.0) as u8]);
        }
    }
    out
}

/// Does the count badge belong on the right of the tile for this entry edge? (The corner that shows first.)
pub fn badge_right(edge: Edge) -> bool {
    edge == Edge::Left
}

#[cfg(test)]
mod tests {
    use super::*;

    fn canvas_test(f: impl FnOnce(&mut Canvas)) -> Vec<u32> {
        let mut px = vec![0u32; 320 * 200];
        f(&mut Canvas { w: 320, h: 200, px: &mut px });
        px
    }

    fn sprite() -> Sprite {
        let img = Image { w: 4, h: 2, rgba: [200u8, 10, 10, 255].repeat(8) };
        build_sprite(Some(&img), 64.0, 1.0, 3, false, Some(&Mask { w: 2, h: 2, a: vec![255; 4] }))
    }

    #[test]
    fn the_tile_is_opaque_in_the_middle_and_clear_at_the_corners() {
        let s = sprite();
        assert_eq!(s.px[s.h / 2 * s.w + s.w / 2] >> 24, 255);
        assert_eq!(s.px[0], 0);
    }

    #[test]
    fn a_sprite_clips_at_every_edge_and_far_beyond() {
        let s = sprite();
        for (cx, cy) in [(0.0, 0.0), (320.0, 200.0), (-500.0, 100.0), (900.0, 100.0), (100.0, -700.0), (100.0, 900.0), (160.0, 100.0)] {
            for (scale, rot, alpha) in [(1.0, 0.0, 1.0), (1.0, 0.0, 0.5), (0.2, 0.07, 1.0), (1.0, 0.07, 0.3), (0.0, 0.0, 1.0)] {
                canvas_test(|c| {
                    c.sprite(&s, &TilePose { cx, cy, scale, rot, alpha, edge: Edge::Right });
                });
            }
        }
    }

    #[test]
    fn a_half_faded_tile_stays_valid_premultiplied() {
        let s = sprite();
        let px = canvas_test(|c| {
            c.sprite(&s, &TilePose { cx: 160.0, cy: 100.0, scale: 1.0, rot: 0.0, alpha: 0.5, edge: Edge::Right });
        });
        for p in px {
            let a = p >> 24;
            assert!((p >> 16 & 255) <= a + 1 && (p >> 8 & 255) <= a + 1 && (p & 255) <= a + 1, "{p:08x}");
        }
    }

    #[test]
    fn glass_and_glow_clip_everywhere_and_report_what_they_touched() {
        for seam in [(320.0, 100.0), (0.0, 100.0), (160.0, 0.0), (160.0, 200.0), (-40.0, -40.0)] {
            for (men, front) in [(30.0, -1.0), (30.0, 5.0), (0.0, 60.0), (0.0, 400.0), (0.0, 0.0)] {
                let g = Glass { seam, mm_per_px: 0.26, men, front, fade: 0.7 };
                let mut r = Rect::default();
                let px = canvas_test(|c| r = c.glass(&g));
                for (i, p) in px.iter().enumerate() {
                    if *p != 0 {
                        let (x, y) = ((i % 320) as i32, (i / 320) as i32);
                        assert!(x >= r.x0 && x < r.x1 && y >= r.y0 && y < r.y1, "pixel outside the dirty rect: {x},{y} {r:?}");
                    }
                }
            }
            let mut r = Rect::default();
            canvas_test(|c| r = c.glow(&Glow { at: seam, radius: 40.0, strength: 0.5 }));
        }
    }

    #[test]
    fn clearing_the_dirty_rect_leaves_nothing_behind() {
        let s = sprite();
        let mut px = vec![0u32; 320 * 200];
        let mut c = Canvas { w: 320, h: 200, px: &mut px };
        let a = c.sprite(&s, &TilePose { cx: 300.0, cy: 20.0, scale: 0.6, rot: 0.07, alpha: 1.0, edge: Edge::Right });
        let b = c.glass(&Glass { seam: (320.0, 100.0), mm_per_px: 0.26, men: 20.0, front: 30.0, fade: 1.0 });
        c.clear(a.union(b));
        assert!(px.iter().all(|p| *p == 0));
    }

    #[test]
    fn tray_glyphs_differ_only_by_the_hole() {
        let (ring, disc) = (tray_glyph(32, false, [255, 255, 255]), tray_glyph(32, true, [255, 255, 255]));
        let at = |v: &[u8], x: usize, y: usize| v[(y * 32 + x) * 4 + 3];
        assert_eq!((at(&ring, 16, 16), at(&disc, 16, 16)), (0, 255));
        assert_eq!(at(&ring, 16, 7), 255);
        assert_eq!(at(&ring, 1, 1), 0);
    }

    #[test]
    fn thumbnails_come_out_as_the_square_jpeg_the_phone_expects() {
        let wide = Image { w: 800, h: 400, rgba: [0u8, 0, 255, 128].repeat(800 * 400) };
        let t = crate::thumb::square_jpeg(&wide).unwrap();
        assert!(!t.contains('\n'));
        let back = decode_b64(&t).unwrap();
        assert_eq!((back.w, back.h), (512, 512));
        assert!(back.rgba[0] > 100, "transparency flattened on white: {:?}", &back.rgba[..4]);
    }

    #[test]
    fn broken_thumbnails_are_just_missing() {
        assert!(decode_b64("not base64!").is_none());
        assert!(decode_b64("aGVsbG8=").is_none());
    }
}
