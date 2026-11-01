//! What the overlay does over time, with no window in sight: `Overlay.swift`'s tile and connect ceremony, in pixels.
//! Cues go in, one `Scene` per display frame comes out. Keep the numbers in step with the Mac.
use crate::server::{Cue, Edge};

const SHRINK_AT: f64 = 0.55; // seconds after commit: the tile shrinks away where it landed

pub fn smoothstep(a: f64, b: f64, x: f64) -> f64 {
    let t = ((x - a) / (b - a)).clamp(0.0, 1.0);
    t * t * (3.0 - 2.0 * t)
}

/// Radius of the wave in mm, `t` seconds after it starts. Same on every screen.
pub fn front_mm(t: f64, screen_w_mm: f64) -> f64 {
    0.66 * screen_w_mm * (1.0 - (-t / 0.30).exp())
}

/// Radius of the lens in mm for a hold of `p` (0…1). Same on every screen.
pub fn lens_mm(p: f64) -> f64 {
    10.0 + 24.0 * p
}

/// Critically damped.
#[derive(Clone, Copy, Default, Debug)]
pub struct Spring {
    pub x: f64,
    pub v: f64,
}

impl Spring {
    pub fn step(&mut self, g: f64, w: f64, dt: f64) {
        let (d, c, e) = (self.x - g, self.v + w * (self.x - g), (-w * dt).exp());
        self.x = g + (d + c * dt) * e;
        self.v = (c - w * (d + c * dt)) * e;
    }
}

/// The primary screen, in physical pixels.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct ScreenInfo {
    pub w: f64,
    pub h: f64,
    pub mm: (f64, f64),
    /// physical pixels per Mac point (DPI / 96)
    pub scale: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct TilePose {
    pub cx: f64,
    pub cy: f64,
    pub scale: f64,
    pub rot: f64, // radians, clockwise on screen
    pub alpha: f64,
    pub edge: Edge,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Glass {
    pub seam: (f64, f64),
    pub mm_per_px: f64,
    pub men: f64,   // lens radius in mm, 0 = none
    pub front: f64, // wave radius in mm, < 0 = none
    pub fade: f64,
}

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Glow {
    pub at: (f64, f64),
    pub radius: f64,
    pub strength: f64,
}

#[derive(Clone, Copy, Debug, PartialEq, Default)]
pub struct Scene {
    pub tile: Option<TilePose>,
    pub glass: Option<Glass>,
    pub glow: Option<Glow>,
}

#[derive(Clone, Copy, PartialEq, Debug)]
enum Mode {
    Hidden,
    Dragging,
    Settled,
    Retracting,
    Landing,
    Pairing,
    Outgoing,
    OutBurst,
}

pub struct Stage {
    mode: Mode,
    cur_over: f64,
    cur_along: f64,
    tgt_over: f64,
    tgt_along: f64,
    want_over: f64,
    edge: Edge,
    want_edge: Edge,
    tile: f64, // pixels
    aspect: f64,
    v_span: f64, // phone screen as a share of this screen (set per drag)
    h_span: f64,
    alpha: f64,
    land_t: f64,
    fx_t: f64,
    thrust: f64, // the tile lands past its resting place, in tile sizes
    tilt: f64,
    travel: Spring,
    flying: bool,
    over_v: f64,
    along_v: f64,
    last_over: f64,
    last_along: f64,
    fly_p: f64,
    clock: f64,
    pair_p: f64,
    pair_link: Spring,
    pair_t: f64, // seconds since the wave started, -1 = not yet
    pair_last: f64,
    seam: Edge,
    glow_v: f64,
}

impl Default for Stage {
    fn default() -> Self {
        Stage {
            mode: Mode::Hidden,
            cur_over: 0.0,
            cur_along: 0.5,
            tgt_over: 0.0,
            tgt_along: 0.5,
            want_over: 0.0,
            edge: Edge::Right,
            want_edge: Edge::Right,
            tile: 96.0,
            aspect: 1.0,
            v_span: 0.85,
            h_span: 0.30,
            alpha: 1.0,
            land_t: 0.0,
            fx_t: 0.0,
            thrust: 0.0,
            tilt: 0.0,
            travel: Spring::default(),
            flying: false,
            over_v: 0.0,
            along_v: 0.0,
            last_over: 0.0,
            last_along: 0.5,
            fly_p: 0.0,
            clock: 0.0,
            pair_p: 0.0,
            pair_link: Spring::default(),
            pair_t: -1.0,
            pair_last: -1.0,
            seam: Edge::Right,
            glow_v: 0.0,
        }
    }
}

impl Stage {
    pub fn visible(&self) -> bool {
        self.mode != Mode::Hidden
    }

    /// Tile side in pixels for the current drag.
    pub fn tile_px(&self) -> f64 {
        self.tile
    }

    pub fn edge(&self) -> Edge {
        self.edge
    }

    pub fn cue(&mut self, c: &Cue, s: &ScreenInfo) {
        match *c {
            Cue::DragStart { ref image, tile_dp, tile_mm, phone_mm, .. } => {
                let mm_per_px = s.mm.0 / s.w;
                self.tile = match tile_mm {
                    Some(t) if t > 5.0 => (t / mm_per_px).clamp(48.0 * s.scale, 500.0 * s.scale), // same physical size
                    _ => tile_dp.clamp(48.0, 400.0) * 0.91 * s.scale,
                };
                if let Some((w, h)) = phone_mm.filter(|p| p.0 > 20.0 && p.1 > 20.0) {
                    self.v_span = (h / s.mm.1).clamp(0.2, 1.0); // phone screen as a share of this one (physical)
                    self.h_span = (w / s.mm.0).clamp(0.1, 1.0);
                }
                self.aspect = image.as_ref().map_or(1.0, |i| if i.h > 0 { i.w as f64 / i.h as f64 } else { 1.0 });
                *self = Stage { mode: Mode::Dragging, edge: self.edge, want_edge: self.want_edge, seam: self.seam, clock: self.clock, tile: self.tile, aspect: self.aspect, v_span: self.v_span, h_span: self.h_span, ..Stage::default() };
            }
            Cue::DragMove { phone_edge, overhang, along } => {
                if self.mode != Mode::Dragging {
                    return;
                }
                self.want_edge = phone_edge.opposite();
                self.want_over = overhang.clamp(0.0, 1.0);
                self.tgt_along = along.clamp(0.0, 1.0);
                if self.cur_over < 0.003 {
                    self.edge = self.want_edge;
                }
            }
            Cue::Settle => {
                self.mode = Mode::Settled;
                self.tgt_over = 1.0;
                self.fx_t = 0.0;
            }
            Cue::Retract => self.retract(),
            Cue::Land => {
                self.mode = Mode::Landing;
                self.tgt_over = 1.0;
                self.land_t = 0.0;
            }
            Cue::Cancel => {
                if self.mode != Mode::Hidden {
                    self.retract();
                }
            }
            // only the first burst counts: a hold still on its way when the wave has started must not begin another one
            Cue::PairHold { p, seam } => {
                let allowed = if self.mode == Mode::Pairing { self.pair_t < 0.0 } else { self.mode == Mode::Hidden };
                if !allowed {
                    return;
                }
                if self.mode != Mode::Pairing {
                    self.mode = Mode::Pairing;
                    self.pair_link = Spring::default();
                    self.pair_t = -1.0;
                }
                self.seam = seam;
                self.pair_p = p.clamp(0.0, 1.0);
                self.pair_last = self.clock;
            }
            Cue::PairBurst => {
                if self.mode == Mode::Pairing && self.pair_t < 0.0 {
                    self.pair_t = 0.0;
                }
            }
            Cue::PairCancel => self.pair_last = f64::NEG_INFINITY,
            Cue::OutMove { edge, overhang, along } => {
                if self.mode != Mode::Outgoing {
                    *self = Stage { mode: Mode::Outgoing, clock: self.clock, tile: self.tile, ..Stage::default() };
                }
                self.edge = edge;
                self.tgt_over = overhang.clamp(0.0, 1.0);
                self.tgt_along = along.clamp(0.0, 1.0);
            }
            Cue::OutEnd { commit } => {
                if self.mode != Mode::Outgoing {
                    return;
                }
                if commit {
                    self.mode = Mode::OutBurst;
                    self.fx_t = 0.0;
                } else {
                    self.mode = Mode::Retracting;
                    self.tgt_over = 0.0;
                }
            }
        }
    }

    fn retract(&mut self) {
        self.mode = Mode::Retracting;
        self.tgt_over = 0.0;
        self.thrust = 0.0;
        self.tilt = 0.0;
        self.flying = false;
    }

    fn hide(&mut self) -> Scene {
        self.mode = Mode::Hidden;
        Scene::default()
    }

    fn seam_px(s: &ScreenInfo, e: Edge, along: f64) -> (f64, f64) {
        match e {
            Edge::Left => (0.0, along * s.h),
            Edge::Top => (along * s.w, 0.0),
            Edge::Bottom => (along * s.w, s.h),
            Edge::Right => (s.w, along * s.h),
        }
    }

    pub fn tick(&mut self, dt: f64, s: &ScreenInfo) -> Scene {
        let dt = dt.min(0.1);
        self.clock += dt;
        match self.mode {
            Mode::Hidden => Scene::default(),
            Mode::Pairing => self.pair_tick(dt, s),
            Mode::Outgoing | Mode::OutBurst => self.out_tick(dt, s),
            Mode::Retracting if self.glow_v > 0.0 => self.out_tick(dt, s),
            _ => self.tile_tick(dt, s),
        }
    }

    fn pair_tick(&mut self, dt: f64, s: &ScreenInfo) -> Scene {
        let held = self.clock - self.pair_last < 0.4 || self.pair_t >= 0.0;
        self.pair_link.step(if held { 1.0 } else { 0.0 }, 9.0, dt);
        let mut men = self.pair_link.x * lens_mm(self.pair_p);
        let (mut front, mut fade) = (-1.0, 1.0);
        if self.pair_t >= 0.0 {
            self.pair_t += dt;
            front = front_mm(self.pair_t, s.mm.0);
            fade = 1.0 - smoothstep(0.45, 0.95, self.pair_t);
            men *= (-self.pair_t / 0.08).exp();
            if self.pair_t > 1.0 {
                return self.hide();
            }
        } else if !held && self.pair_link.x < 0.01 {
            return self.hide();
        }
        Scene { glass: Some(Glass { seam: Self::seam_px(s, self.seam, 0.5), mm_per_px: s.mm.0 / s.w, men, front, fade }), ..Scene::default() }
    }

    /// Computer → phone: the file is under the cursor, so there is no tile here; the edge answers with a soft light,
    /// and on commit with the same wave the ceremony uses.
    fn out_tick(&mut self, dt: f64, s: &ScreenInfo) -> Scene {
        let k = 1.0 - (-dt * 70.0).exp();
        self.cur_over += (self.tgt_over - self.cur_over) * k;
        self.cur_along += (self.tgt_along - self.cur_along) * k;
        self.glow_v = self.cur_over.max(1e-3);
        let at = Self::seam_px(s, self.edge, self.cur_along);
        let mm_per_px = s.mm.0 / s.w;
        match self.mode {
            Mode::OutBurst => {
                self.fx_t += dt;
                if self.fx_t > 1.0 {
                    return self.hide();
                }
                let fade = 1.0 - smoothstep(0.45, 0.95, self.fx_t);
                let front = front_mm(self.fx_t, s.mm.0);
                Scene {
                    glass: Some(Glass { seam: at, mm_per_px, men: 0.0, front, fade }),
                    glow: Some(Glow { at, radius: 34.0 / mm_per_px, strength: 0.5 * (-self.fx_t / 0.12).exp() }),
                    ..Scene::default()
                }
            }
            Mode::Retracting if self.cur_over < 0.01 => self.hide(),
            _ => Scene { glow: Some(Glow { at, radius: 34.0 / mm_per_px, strength: 0.5 * smoothstep(0.0, 1.0, self.cur_over) }), ..Scene::default() },
        }
    }

    fn tile_tick(&mut self, dt: f64, s: &ScreenInfo) -> Scene {
        let k = 1.0 - (-dt * 70.0).exp(); // light smoothing (~14ms) so the tile tracks the finger without trailing
        if self.mode == Mode::Dragging {
            if self.want_edge != self.edge {
                self.tgt_over = 0.0; // edge changed mid-drag: slide out the old one first
                if self.cur_over < 0.02 {
                    self.edge = self.want_edge;
                    self.cur_over = 0.0;
                }
            } else {
                self.tgt_over = self.want_over;
            }
            if self.cur_over < 0.003 {
                self.cur_along = self.tgt_along;
            }
        }
        self.cur_over += (self.tgt_over - self.cur_over) * k;
        self.cur_along += (self.tgt_along - self.cur_along) * k;
        let committed = matches!(self.mode, Mode::Settled | Mode::Landing);
        if committed {
            self.fx_t += dt;
            // the tile never stops: it carries its speed across the seam to its place
            let inward = if self.edge.vertical() { s.w } else { s.h };
            if !self.flying {
                self.flying = true;
                self.travel = Spring { x: self.cur_over, v: self.over_v.clamp(0.0, 12.0) };
                self.tgt_along = (self.cur_along + self.along_v * 0.18).clamp(0.08, 0.92);
            }
            self.travel.step(1.0 + 0.42 * inward / self.tile, 9.0, dt);
            self.thrust = self.travel.x - self.cur_over;
            self.tilt = -0.07 * (1.0 - (-self.fx_t * 10.0).exp());
        } else {
            self.over_v += ((self.cur_over - self.last_over) / dt.max(0.001) - self.over_v) * 0.35;
            self.along_v += ((self.cur_along - self.last_along) / dt.max(0.001) - self.along_v) * 0.35;
        }
        self.last_over = self.cur_over;
        self.last_along = self.cur_along;
        match self.mode {
            Mode::Retracting if self.cur_over < 0.003 => return self.hide(),
            Mode::Landing => {
                self.land_t += dt;
                let wait = (SHRINK_AT - (self.fx_t - self.land_t)).max(0.0);
                self.fly_p = ((self.land_t - wait) / 0.2).clamp(0.0, 1.0);
                self.alpha = 1.0 - smoothstep(0.5, 1.0, self.fly_p);
                if self.land_t >= wait + 0.2 {
                    return self.hide();
                }
            }
            _ => {}
        }
        if self.cur_over < 0.003 {
            return Scene::default();
        }
        let (w, h, t) = (s.w, s.h, self.tile);
        let d = (self.cur_over + self.thrust) * t;
        let span = if self.edge.vertical() { self.v_span } else { self.h_span };
        // the phone is shorter than this screen and centred next to it, so the tile continues where it left the phone
        let a = 0.5 + (self.cur_along - 0.5) * span;
        let along_px = |len: f64| (a * len - t / 2.0).min(len - t - 8.0).max(8.0);
        let (x, y) = match self.edge {
            Edge::Right => (w - d, along_px(h)),
            Edge::Left => (d - t, along_px(h)),
            Edge::Top => (along_px(w), d - t),
            Edge::Bottom => (along_px(w), h - d),
        };
        let entering = if self.mode == Mode::Dragging { 0.55 + 0.45 * smoothstep(0.1, 0.7, self.cur_over) } else { 1.0 }; // arrives as a pale ghost, then solid
        Scene {
            tile: Some(TilePose {
                cx: x + t / 2.0,
                cy: y + t / 2.0,
                scale: 1.0 - 0.8 * smoothstep(0.0, 1.0, self.fly_p),
                rot: -self.tilt * (1.0 - self.fly_p),
                alpha: self.alpha * entering,
                edge: self.edge,
            }),
            ..Scene::default()
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const S: ScreenInfo = ScreenInfo { w: 1920.0, h: 1080.0, mm: (510.0, 287.0), scale: 1.0 };
    const DT: f64 = 1.0 / 60.0;

    fn start(st: &mut Stage) {
        st.cue(&Cue::DragStart { image: None, tile_dp: 192.0, tile_mm: Some(35.5), phone_mm: Some((68.0, 148.0)), count: 1 }, &S);
    }

    fn run(st: &mut Stage, secs: f64) -> Scene {
        let mut last = Scene::default();
        for _ in 0..(secs / DT) as usize {
            last = st.tick(DT, &S);
        }
        last
    }

    #[test]
    fn the_tile_keeps_its_physical_size() {
        let mut st = Stage::default();
        start(&mut st);
        assert!((st.tile_px() - 35.5 * 1920.0 / 510.0).abs() < 0.01);
    }

    #[test]
    fn the_tile_enters_through_the_edge_opposite_the_phone_edge() {
        for (phone, check) in [
            (Edge::Left, (|p: &TilePose| p.cx > 1800.0) as fn(&TilePose) -> bool),
            (Edge::Right, |p| p.cx < 120.0),
            (Edge::Top, |p| p.cy > 960.0),
            (Edge::Bottom, |p| p.cy < 120.0),
        ] {
            let mut st = Stage::default();
            start(&mut st);
            st.cue(&Cue::DragMove { phone_edge: phone, overhang: 0.5, along: 0.5 }, &S);
            let pose = run(&mut st, 0.4).tile.expect("tile on screen");
            assert!(check(&pose), "{phone:?}: {pose:?}");
            assert_eq!(st.edge(), phone.opposite());
        }
    }

    #[test]
    fn visible_depth_follows_overhang_and_along_follows_the_edge() {
        let mut st = Stage::default();
        start(&mut st);
        st.cue(&Cue::DragMove { phone_edge: Edge::Left, overhang: 0.25, along: 0.25 }, &S);
        let p = run(&mut st, 0.4).tile.unwrap();
        let t = st.tile_px();
        assert!((p.cx - (1920.0 - 0.25 * t + t / 2.0)).abs() < 1.0, "{p:?}");
        let span = 148.0 / 287.0;
        assert!((p.cy - (0.5 - 0.25 * span) * 1080.0).abs() < 1.0, "{p:?}");
    }

    #[test]
    fn nothing_shows_while_the_tile_is_fully_on_the_phone() {
        let mut st = Stage::default();
        start(&mut st);
        st.cue(&Cue::DragMove { phone_edge: Edge::Left, overhang: 0.0, along: 0.5 }, &S);
        assert_eq!(run(&mut st, 0.2).tile, None);
        assert!(st.visible());
    }

    #[test]
    fn changing_edge_slides_out_first() {
        let mut st = Stage::default();
        start(&mut st);
        st.cue(&Cue::DragMove { phone_edge: Edge::Left, overhang: 0.8, along: 0.5 }, &S);
        run(&mut st, 0.3);
        st.cue(&Cue::DragMove { phone_edge: Edge::Top, overhang: 0.8, along: 0.5 }, &S);
        let during = st.tick(DT, &S).tile.unwrap();
        assert_eq!(during.edge, Edge::Right, "still leaving through the old edge");
        assert_eq!(run(&mut st, 0.4).tile.unwrap().edge, Edge::Bottom);
    }

    #[test]
    fn a_cancelled_drag_retracts_and_hides() {
        let mut st = Stage::default();
        start(&mut st);
        st.cue(&Cue::DragMove { phone_edge: Edge::Left, overhang: 0.4, along: 0.5 }, &S);
        run(&mut st, 0.3);
        st.cue(&Cue::Retract, &S);
        run(&mut st, 0.5);
        assert!(!st.visible());
    }

    #[test]
    fn a_throw_flies_in_without_a_jump_then_lands_and_hides() {
        let mut st = Stage::default();
        start(&mut st);
        for i in 0..30 {
            st.cue(&Cue::DragMove { phone_edge: Edge::Left, overhang: i as f64 / 30.0 * 0.7, along: 0.5 }, &S);
            st.tick(DT, &S);
        }
        let before = st.tick(DT, &S).tile.unwrap();
        st.cue(&Cue::Settle, &S);
        let after = st.tick(DT, &S).tile.unwrap();
        assert!(after.cx < before.cx && before.cx - after.cx < 60.0, "{before:?} {after:?}");
        let settled = run(&mut st, 1.2).tile.unwrap();
        assert!((1920.0 - settled.cx) > 0.3 * 1920.0, "{settled:?}");
        st.cue(&Cue::Land, &S);
        let mid = run(&mut st, 0.1).tile.unwrap();
        assert!(mid.scale < 1.0);
        run(&mut st, 0.3);
        assert!(!st.visible());
    }

    #[test]
    fn a_slow_transfer_still_waits_for_the_landing_beat() {
        let mut st = Stage::default();
        start(&mut st);
        st.cue(&Cue::DragMove { phone_edge: Edge::Left, overhang: 0.7, along: 0.5 }, &S);
        run(&mut st, 0.3);
        st.cue(&Cue::Settle, &S);
        st.cue(&Cue::Land, &S); // a tiny file: saved at once
        assert_eq!(run(&mut st, 0.4).tile.unwrap().scale, 1.0, "still flying");
        run(&mut st, 0.5);
        assert!(!st.visible());
    }

    #[test]
    fn only_the_first_burst_counts() {
        let mut st = Stage::default();
        let hold = Cue::PairHold { p: 0.8, seam: Edge::Right };
        st.cue(&hold, &S);
        let g = run(&mut st, 0.5).glass.unwrap();
        assert!(g.men > 0.5 * lens_mm(0.8) && g.front < 0.0);
        assert_eq!(g.seam, (1920.0, 540.0));
        st.cue(&Cue::PairBurst, &S);
        run(&mut st, 0.2);
        let t = st.pair_t;
        st.cue(&hold, &S); // still in flight
        st.cue(&Cue::PairBurst, &S);
        assert_eq!(st.pair_t, t, "the wave did not restart");
        let late = run(&mut st, 0.1).glass.unwrap();
        assert!(late.front > 0.0);
        run(&mut st, 1.0);
        assert!(!st.visible());
        st.cue(&Cue::PairBurst, &S);
        assert!(!st.visible(), "a burst with no hold starts nothing");
    }

    #[test]
    fn letting_go_of_the_hold_lets_the_lens_go() {
        let mut st = Stage::default();
        st.cue(&Cue::PairHold { p: 0.5, seam: Edge::Left }, &S);
        run(&mut st, 0.3);
        st.cue(&Cue::PairCancel, &S);
        run(&mut st, 1.0);
        assert!(!st.visible());
    }

    #[test]
    fn a_stalled_hold_times_out() {
        let mut st = Stage::default();
        st.cue(&Cue::PairHold { p: 0.5, seam: Edge::Left }, &S);
        run(&mut st, 2.0);
        assert!(!st.visible());
    }

    #[test]
    fn the_wave_matches_the_other_screens() {
        assert!((front_mm(0.3, 302.0) - 0.66 * 302.0 * (1.0 - (-1.0f64).exp())).abs() < 1e-9);
        assert_eq!(lens_mm(0.0), 10.0);
        assert_eq!(lens_mm(1.0), 34.0);
    }

    #[test]
    fn outgoing_glow_follows_then_bursts_or_fades() {
        let mut st = Stage::default();
        st.cue(&Cue::OutMove { edge: Edge::Right, overhang: 1.0, along: 0.25 }, &S);
        let g = run(&mut st, 0.3).glow.unwrap();
        assert!((g.at.0 - 1920.0).abs() < 1e-6 && (g.at.1 - 270.0).abs() < 1.0);
        st.cue(&Cue::OutEnd { commit: true }, &S);
        assert!(run(&mut st, 0.3).glass.is_some());
        run(&mut st, 1.0);
        assert!(!st.visible());
        st.cue(&Cue::OutMove { edge: Edge::Top, overhang: 0.8, along: 0.5 }, &S);
        run(&mut st, 0.2);
        st.cue(&Cue::OutEnd { commit: false }, &S);
        run(&mut st, 0.5);
        assert!(!st.visible());
    }
}
