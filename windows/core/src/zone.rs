//! The edge that leads to the phone, for a drag going out: the numbers from `MacDrag.swift`, and who gets to end the
//! drag. The drop and the button coming up are noticed on different threads, in either order, and the thumbnail may
//! still be on its way when both have happened.
use crate::send::OutDrag;
use crate::server::{lock, Edge, Server};
use crate::stage::ScreenInfo;
use std::path::PathBuf;
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;

pub const ZONE_PT: f64 = 24.0;
pub const COMMIT_PT: f64 = 4.0;
/// A catch strip only appears this close to the edge: most presses never get here.
pub const ARM_PT: f64 = 120.0;

/// (distance to the edge in px, negative once past it; along 0…1 in reading direction)
pub fn geometry(x: f64, y: f64, e: Edge, s: &ScreenInfo) -> (f64, f64) {
    match e {
        Edge::Left => (x, y / s.h),
        Edge::Top => (y, x / s.w),
        Edge::Bottom => (s.h - 1.0 - y, x / s.w),
        Edge::Right => (s.w - 1.0 - x, y / s.h),
    }
}

/// 0 at the start of the zone, 1 on the edge, and 0 again past it: that is another monitor, not the phone.
pub fn overhang(dist: f64, s: &ScreenInfo) -> f64 {
    if dist < 0.0 {
        return 0.0;
    }
    (1.0 - dist / (ZONE_PT * s.scale)).clamp(0.0, 1.0)
}

pub fn commits(dist: f64, s: &ScreenInfo) -> bool {
    (0.0..=COMMIT_PT * s.scale).contains(&dist)
}

/// Should a press at this distance be left alone? One on the edge itself is not a drag toward it.
pub fn press_counts(dist: f64, s: &ScreenInfo) -> bool {
    dist > ZONE_PT * s.scale
}

pub fn near_enough(dist: f64, s: &ScreenInfo) -> bool {
    dist >= 0.0 && dist <= ARM_PT * s.scale
}

/// The strip along the edge: (left, top, right, bottom) in px.
pub fn strip(e: Edge, s: &ScreenInfo) -> (i32, i32, i32, i32) {
    let (w, h, z) = (s.w as i32, s.h as i32, (ZONE_PT * s.scale).ceil() as i32);
    match e {
        Edge::Left => (0, 0, z, h),
        Edge::Right => (w - z, 0, w, h),
        Edge::Top => (0, 0, w, z),
        Edge::Bottom => (0, h - z, w, h),
    }
}

enum Out {
    None,
    /// Waiting for the thumbnail; `end` = the drag is already over, with this commit.
    Starting { end: Option<bool> },
    Live(OutDrag),
}

/// One outgoing drag at a time, from the moment files are known until it ended.
pub struct Handoff {
    srv: Arc<Server>,
    out: Mutex<Out>,
    accepting: AtomicBool,
}

impl Handoff {
    pub fn new(srv: Arc<Server>) -> Arc<Handoff> {
        Arc::new(Handoff { srv, out: Mutex::new(Out::None), accepting: AtomicBool::new(false) })
    }

    pub fn server(&self) -> &Arc<Server> {
        &self.srv
    }

    /// May the drag land here? Lock-free: the program the file came from is waiting on this answer.
    pub fn accepting(&self) -> bool {
        self.accepting.load(Ordering::Acquire)
    }

    /// Files are over the edge. `thumb` may take a while, so it runs on a thread of its own.
    pub fn begin(self: &Arc<Self>, files: Vec<PathBuf>, thumb: impl FnOnce(&[PathBuf]) -> String + Send + 'static) {
        {
            let mut o = lock(&self.out);
            if !matches!(*o, Out::None) {
                return;
            }
            *o = Out::Starting { end: None };
        }
        self.accepting.store(true, Ordering::Release);
        let me = self.clone();
        thread::spawn(move || {
            let t = thumb(&files);
            let d = me.srv.out_start(files, t);
            let mut o = lock(&me.out);
            let end = if let Out::Starting { end } = *o { end } else { None };
            match (d, end) {
                (Some(d), None) => *o = Out::Live(d),
                (Some(d), Some(commit)) => {
                    *o = Out::None;
                    drop(o);
                    d.moved(0.5, if commit { 1.0 } else { 0.0 });
                    d.end(commit);
                }
                (None, _) => {
                    *o = Out::None;
                    me.accepting.store(false, Ordering::Release);
                }
            }
        });
    }

    pub fn moved(&self, along: f64, overhang: f64) {
        if let Out::Live(d) = &*lock(&self.out) {
            d.moved(along, overhang);
        }
    }

    /// The first end counts: the drop itself, then whoever notices the button is up.
    pub fn finish(&self, commit: bool) {
        self.accepting.store(false, Ordering::Release);
        let mut o = lock(&self.out);
        match std::mem::replace(&mut *o, Out::None) {
            Out::Live(d) => {
                thread::spawn(move || d.end(commit)); // a stalled phone must not stall the drag source
            }
            Out::Starting { end } => *o = Out::Starting { end: end.or(Some(commit)) },
            Out::None => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    const S: ScreenInfo = ScreenInfo { w: 1920.0, h: 1080.0, mm: (510.0, 287.0), scale: 1.0 };
    const HI: ScreenInfo = ScreenInfo { w: 3840.0, h: 2160.0, mm: (600.0, 340.0), scale: 2.0 };

    #[test]
    fn distance_and_along_for_every_edge() {
        assert_eq!(geometry(1919.0, 540.0, Edge::Right, &S), (0.0, 0.5));
        assert_eq!(geometry(0.0, 270.0, Edge::Left, &S), (0.0, 0.25));
        assert_eq!(geometry(480.0, 0.0, Edge::Top, &S), (0.0, 0.25));
        assert_eq!(geometry(960.0, 1079.0, Edge::Bottom, &S), (0.0, 0.5));
        assert_eq!(geometry(1896.0, 0.0, Edge::Right, &S).0, 23.0);
    }

    #[test]
    fn overhang_runs_through_the_zone_and_stops_at_the_edge() {
        assert_eq!(overhang(24.0, &S), 0.0);
        assert_eq!(overhang(12.0, &S), 0.5);
        assert_eq!(overhang(0.0, &S), 1.0);
        assert_eq!(overhang(-5.0, &S), 0.0, "past the edge is another monitor");
        assert_eq!(overhang(24.0, &HI), 0.5, "points, not pixels");
    }

    #[test]
    fn only_the_last_four_points_commit() {
        assert!(commits(0.0, &S) && commits(4.0, &S));
        assert!(!commits(4.5, &S) && !commits(-1.0, &S));
        assert!(commits(8.0, &HI));
    }

    #[test]
    fn a_press_on_the_edge_is_left_alone_and_the_strip_stays_near_it() {
        assert!(!press_counts(10.0, &S) && press_counts(30.0, &S));
        assert!(near_enough(120.0, &S) && !near_enough(121.0, &S) && !near_enough(-1.0, &S));
    }

    #[test]
    fn the_strip_lies_along_the_edge() {
        assert_eq!(strip(Edge::Right, &S), (1896, 0, 1920, 1080));
        assert_eq!(strip(Edge::Left, &S), (0, 0, 24, 1080));
        assert_eq!(strip(Edge::Top, &S), (0, 0, 1920, 24));
        assert_eq!(strip(Edge::Bottom, &HI), (0, 2112, 3840, 2160));
    }
}
