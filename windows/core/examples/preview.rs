//! Draws what the overlay draws onto a plain backdrop and writes PNGs: the only way to look at it without Windows.
//! `preview OUT_DIR`
use lidrop_core::render::{build_sprite, Canvas, Image, Mask, Rect};
use lidrop_core::server::{Cue, Edge};
use lidrop_core::stage::{ScreenInfo, Stage};
use std::time::Instant;

const S: ScreenInfo = ScreenInfo { w: 1920.0, h: 1080.0, mm: (510.0, 287.0), scale: 1.0 };

fn photo() -> Image {
    let (w, h) = (512u32, 384u32);
    let mut rgba = Vec::with_capacity((w * h * 4) as usize);
    for y in 0..h {
        for x in 0..w {
            let (u, v) = (x as f32 / w as f32, y as f32 / h as f32);
            rgba.extend_from_slice(&[(40.0 + 200.0 * u) as u8, (90.0 + 120.0 * v) as u8, (190.0 - 120.0 * u * v) as u8, 255]);
        }
    }
    Image { w, h, rgba }
}

fn save(px: &[u32], name: &str, dir: &str) {
    // over a mid-grey "desktop", the way DWM composites premultiplied pixels
    let mut out = Vec::with_capacity(px.len() * 3);
    for (i, c) in px.iter().enumerate() {
        let (x, y) = (i % S.w as usize, i / S.w as usize);
        let bg = [70.0 + 60.0 * (x as f64 / S.w), 80.0 + 40.0 * (y as f64 / S.h), 105.0];
        let a = (c >> 24) as f64 / 255.0;
        let p = [(c >> 16) & 255, (c >> 8) & 255, c & 255];
        for k in 0..3 {
            out.push((p[k] as f64 + bg[k] * (1.0 - a)).min(255.0) as u8);
        }
    }
    image::save_buffer(format!("{dir}/{name}.png"), &out, S.w as u32, S.h as u32, image::ExtendedColorType::Rgb8).unwrap();
}

fn seven(ch: u8) -> Mask {
    // a crude digit: the real app asks Windows for the glyph
    let (w, h) = (14usize, 22usize);
    let mut a = vec![0u8; w * h];
    for y in 0..h {
        for x in 0..w {
            if (ch == b'3') && (y < 3 || y >= h - 3 || (y >= 10 && y < 13) || x >= w - 3) {
                a[y * w + x] = 255;
            }
        }
    }
    Mask { w, h, a }
}

fn main() {
    let dir = std::env::args().nth(1).expect("output folder");
    let img = photo();
    let mut px = vec![0u32; (S.w * S.h) as usize];

    // a tile being thrown in from the right, then flying, one file and a stack
    for (name, count, edge, over) in [("tile_entering", 1, Edge::Left, 0.45), ("stack_entering_left", 3, Edge::Right, 0.8)] {
        let mut st = Stage::default();
        st.cue(&Cue::DragStart { image: Some(img.clone()), tile_dp: 192.0, tile_mm: Some(35.5), phone_mm: Some((68.0, 148.0)), count }, &S);
        st.cue(&Cue::DragMove { phone_edge: edge, overhang: over, along: 0.4 }, &S);
        let mut scene = Default::default();
        for _ in 0..30 {
            scene = st.tick(1.0 / 60.0, &S);
        }
        let mask = seven(b'3');
        let t0 = Instant::now();
        let sprite = build_sprite(Some(&img), st.tile_px(), S.scale, count, lidrop_core::render::badge_right(edge.opposite()), Some(&mask));
        println!("{name}: tile {:.0}px sprite {}x{} built in {:?}", st.tile_px(), sprite.w, sprite.h, t0.elapsed());
        px.fill(0);
        let mut c = Canvas { w: S.w as usize, h: S.h as usize, px: &mut px };
        c.sprite(&sprite, &scene.tile.unwrap());
        save(&px, name, &dir);
        // and in flight after commit
        st.cue(&Cue::Settle, &S);
        for _ in 0..24 {
            scene = st.tick(1.0 / 60.0, &S);
        }
        px.fill(0);
        let mut c = Canvas { w: S.w as usize, h: S.h as usize, px: &mut px };
        let t0 = Instant::now();
        c.sprite(&sprite, &scene.tile.unwrap());
        println!("  rotated draw {:?}", t0.elapsed());
        save(&px, &format!("{name}_flight"), &dir);
    }

    // the ceremony: lens at full hold, the wave early and late
    let mut st = Stage::default();
    st.cue(&Cue::PairHold { p: 0.9, seam: Edge::Right }, &S);
    let mut scene = Default::default();
    for _ in 0..40 {
        st.cue(&Cue::PairHold { p: 0.9, seam: Edge::Right }, &S);
        scene = st.tick(1.0 / 60.0, &S);
    }
    let g = scene.glass.unwrap();
    px.fill(0);
    Canvas { w: S.w as usize, h: S.h as usize, px: &mut px }.glass(&g);
    save(&px, "lens", &dir);
    st.cue(&Cue::PairBurst, &S);
    for (name, frames) in [("wave_early", 12), ("wave_late", 18)] {
        for _ in 0..frames {
            scene = st.tick(1.0 / 60.0, &S);
        }
        px.fill(0);
        let t0 = Instant::now();
        Canvas { w: S.w as usize, h: S.h as usize, px: &mut px }.glass(&scene.glass.unwrap());
        println!("{name}: {:?}", t0.elapsed());
        save(&px, name, &dir);
    }

    // computer → phone: the pool of light at the edge
    let mut st = Stage::default();
    st.cue(&Cue::OutMove { edge: Edge::Right, overhang: 1.0, along: 0.4 }, &S);
    for _ in 0..30 {
        scene = st.tick(1.0 / 60.0, &S);
    }
    px.fill(0);
    let r: Rect = Canvas { w: S.w as usize, h: S.h as usize, px: &mut px }.glow(&scene.glow.unwrap());
    println!("glow {r:?}");
    save(&px, "glow", &dir);
}
