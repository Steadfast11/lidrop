//! A fake phone on a real socket, speaking what `android/.../Net.kt`, `Drag.kt` and `Receiver.kt` speak.
use lidrop_core::frame::{self, BLOCK, CHUNK, CHUNK_SIZE, CONTROL};
use lidrop_core::server::{Config, Cue, Edge, Host, Note, Server};
use lidrop_core::zone::Handoff;
use serde_json::{json, Value};
use std::fs;
use std::io::{Read, Write};
use std::net::TcpStream;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::mpsc::{channel, Receiver, Sender};
use std::sync::{Arc, Mutex};
use std::time::{Duration, Instant};

const WAIT: Duration = Duration::from_secs(5);

struct Mock {
    allow: AtomicBool,
    asked: AtomicUsize,
    hold_answer: Mutex<Option<Receiver<bool>>>,
    cues: Mutex<Sender<Cue>>,
    notes: Mutex<Sender<Note>>,
    phones: Mutex<Vec<String>>,
}

impl Host for Mock {
    fn device_name(&self) -> String {
        "Test PC".into()
    }
    fn screen_mm(&self) -> Option<(f64, f64)> {
        Some((510.0, 287.0))
    }
    fn ask_allow(&self, _: &str, gone: &AtomicBool) -> bool {
        self.asked.fetch_add(1, Ordering::SeqCst);
        if let Some(rx) = self.hold_answer.lock().unwrap().take() {
            while !gone.load(Ordering::SeqCst) {
                if let Ok(a) = rx.recv_timeout(Duration::from_millis(10)) {
                    return a;
                }
            }
            return false;
        }
        self.allow.load(Ordering::SeqCst)
    }
    fn cue(&self, c: Cue) {
        let _ = self.cues.lock().unwrap().send(c);
    }
    fn phones(&self, names: Vec<String>) {
        *self.phones.lock().unwrap() = names;
    }
    fn note(&self, n: Note) {
        let _ = self.notes.lock().unwrap().send(n);
    }
}

struct Rig {
    dir: tempfile::TempDir,
    port: u16,
    srv: Arc<Server>,
    host: Arc<Mock>,
    cues: Receiver<Cue>,
    notes: Receiver<Note>,
}

impl Rig {
    fn new() -> Rig {
        let dir = tempfile::tempdir().unwrap();
        Self::in_dir(dir)
    }

    fn in_dir(dir: tempfile::TempDir) -> Rig {
        let (ct, cues) = channel();
        let (nt, notes) = channel();
        let host = Arc::new(Mock {
            allow: AtomicBool::new(true),
            asked: AtomicUsize::new(0),
            hold_answer: Mutex::new(None),
            cues: Mutex::new(ct),
            notes: Mutex::new(nt),
            phones: Mutex::new(Vec::new()),
        });
        let srv = Server::new(
            host.clone(),
            Config { data_dir: dir.path().join("data"), save_dir: dir.path().join("Downloads/lidrop"), port: 0 },
        )
        .unwrap();
        let port = srv.start().unwrap();
        Rig { dir, port, srv, host, cues, notes }
    }

    fn saved_dir(&self) -> PathBuf {
        self.dir.path().join("Downloads/lidrop")
    }

    fn phone(&self) -> Phone {
        Phone::connect(self.port)
    }

    /// A phone that went through Allow and holds its token.
    fn paired(&self, id: &str) -> Phone {
        let mut p = self.phone();
        p.hello(id, "");
        let w = p.expect("welcome");
        assert!(w["token"].is_string());
        p
    }

    fn next_cue(&self, want: impl Fn(&Cue) -> bool) -> Cue {
        let end = Instant::now() + WAIT;
        loop {
            let c = self.cues.recv_timeout(end - Instant::now()).expect("cue");
            if want(&c) {
                return c;
            }
        }
    }

    fn next_note(&self, want: impl Fn(&Note) -> bool) -> Note {
        let end = Instant::now() + WAIT;
        loop {
            let n = self.notes.recv_timeout(end - Instant::now()).expect("note");
            if want(&n) {
                return n;
            }
        }
    }

    fn wait_phones(&self, n: usize) {
        wait_for(|| self.host.phones.lock().unwrap().len() == n, "phone count");
    }
}

fn wait_for(ok: impl Fn() -> bool, what: &str) {
    let end = Instant::now() + WAIT;
    while !ok() {
        assert!(Instant::now() < end, "timed out waiting for {what}");
        std::thread::sleep(Duration::from_millis(5));
    }
}

struct Phone {
    s: TcpStream,
    buf: Vec<u8>,
}

impl Phone {
    fn connect(port: u16) -> Phone {
        let s = TcpStream::connect(("127.0.0.1", port)).unwrap();
        s.set_nodelay(true).unwrap();
        s.set_read_timeout(Some(WAIT)).unwrap();
        Phone { s, buf: Vec::new() }
    }

    fn raw(&mut self, kind: u8, payload: &[u8]) {
        self.s.write_all(&frame::encode(kind, payload)).unwrap();
    }

    fn send(&mut self, m: Value) {
        self.raw(CONTROL, m.to_string().as_bytes());
    }

    fn hello(&mut self, id: &str, token: &str) {
        self.hello_as(id, token, "main");
    }

    fn hello_as(&mut self, id: &str, token: &str, role: &str) {
        self.send(json!({"t": "hello", "name": "Galaxy S24", "v": 0, "id": id, "role": role, "token": token}));
    }

    fn frame(&mut self) -> Option<(u8, Vec<u8>)> {
        let kind = frame::read_frame(&mut self.s, &mut self.buf).ok()??;
        Some((kind, self.buf.clone()))
    }

    fn msg(&mut self) -> Value {
        loop {
            let (kind, b) = self.frame().expect("a frame");
            if kind == CONTROL {
                return serde_json::from_slice(&b).unwrap();
            }
        }
    }

    fn expect(&mut self, t: &str) -> Value {
        for _ in 0..1000 {
            let m = self.msg();
            if m["t"] == t {
                return m;
            }
        }
        panic!("no {t}");
    }

    fn closed(&mut self) -> bool {
        self.s.set_read_timeout(Some(Duration::from_secs(2))).unwrap();
        loop {
            let mut one = [0u8; 4096];
            match self.s.read(&mut one) {
                Ok(0) => return true,
                Ok(_) => continue,
                Err(e) => return e.kind() != std::io::ErrorKind::WouldBlock && e.kind() != std::io::ErrorKind::TimedOut,
            }
        }
    }

    fn drag(&mut self, id: &str, names: &[&str]) {
        let files: Vec<Value> = names.iter().map(|n| json!({"name": n, "size": 1, "mime": "image/jpeg"})).collect();
        self.send(json!({"t": "drag_start", "id": id, "name": names[0], "mime": "image/jpeg", "size": 1, "thumb": thumb(),
            "tile_dp": 192, "tile_mm": 35.5, "screen_mm": [68.0, 148.0], "files": files, "count": names.len()}));
    }

    fn move_to(&mut self, id: &str, edge: &str, along: f64, overhang: f64) {
        self.send(json!({"t": "drag_move", "id": id, "edge": edge, "along": along, "overhang": overhang}));
    }

    fn commit(&mut self, id: &str) {
        self.send(json!({"t": "drag_end", "id": id, "commit": true}));
    }

    fn file(&mut self, id: &str, index: u64, data: &[u8]) {
        self.send(json!({"t": "file_begin", "id": id, "index": index}));
        for c in data.chunks(CHUNK_SIZE) {
            self.raw(CHUNK, c);
        }
        self.send(json!({"t": "file_end", "id": id, "index": index}));
    }

    fn block(&mut self, i: u32, data: &[u8]) {
        let mut b = i.to_be_bytes().to_vec();
        b.extend_from_slice(data);
        self.raw(BLOCK, &b);
    }
}

/// A real JPEG in the phone's shape: 40x20.
fn thumb() -> String {
    use base64::Engine;
    let mut jpeg = Vec::new();
    image::codecs::jpeg::JpegEncoder::new_with_quality(&mut jpeg, 80)
        .encode(&[200u8; 40 * 20 * 3], 40, 20, image::ExtendedColorType::Rgb8)
        .unwrap();
    base64::engine::general_purpose::STANDARD.encode(jpeg)
}

fn data(n: usize) -> Vec<u8> {
    (0..n).map(|i| (i * 31 % 251) as u8).collect()
}

fn saved_path(m: &Value) -> PathBuf {
    PathBuf::from(m["path"].as_str().unwrap())
}

fn only_entries(d: &Path) -> Vec<String> {
    let mut v: Vec<String> = fs::read_dir(d).into_iter().flatten().flatten().map(|e| e.file_name().to_string_lossy().into_owned()).collect();
    v.sort();
    v
}

// ---------- hello, Allow, trust

#[test]
fn hello_without_id_is_refused_as_the_old_fake_phone_found_out() {
    let r = Rig::new();
    let mut p = r.phone();
    p.send(json!({"t": "hello", "name": "Old", "v": 0}));
    assert!(p.closed());
    assert_eq!(r.host.asked.load(Ordering::SeqCst), 0);
}

#[test]
fn a_new_phone_is_asked_once_then_remembered_across_restarts() {
    let r = Rig::new();
    r.srv.set_ticket("endpointabc".into());
    let mut p = r.phone();
    p.hello("phone-1", "");
    let w = p.expect("welcome");
    assert_eq!(w["name"], "Test PC");
    assert_eq!(w["edge"], "right");
    assert_eq!(w["screen_mm"], json!([510.0, 287.0]));
    assert_eq!(w["ticket"], "endpointabc");
    let token = w["token"].as_str().unwrap().to_string();
    assert_eq!(token.len(), 64);
    assert_eq!(r.host.asked.load(Ordering::SeqCst), 1);
    drop(p);
    r.wait_phones(0);

    // the same app after a restart: same folder, new server
    let Rig { dir, .. } = r;
    let r = Rig::in_dir(dir);
    let mut p = r.phone();
    p.hello("phone-1", &token);
    let w = p.expect("welcome");
    assert!(w["token"].is_null(), "a known pair goes straight in");
    assert_eq!(r.host.asked.load(Ordering::SeqCst), 0);
    assert_eq!(*r.host.phones.lock().unwrap(), vec!["Galaxy S24"]);
}

#[test]
fn a_wrong_token_is_asked_again() {
    let r = Rig::new();
    r.paired("phone-1");
    let mut p = r.phone();
    p.hello("phone-1", "not-the-token");
    p.expect("welcome");
    assert_eq!(r.host.asked.load(Ordering::SeqCst), 2);
}

#[test]
fn dont_allow_says_denied_and_hangs_up() {
    let r = Rig::new();
    r.host.allow.store(false, Ordering::SeqCst);
    let mut p = r.phone();
    p.hello("phone-1", "");
    assert_eq!(p.msg()["t"], "denied");
    assert!(p.closed());
}

#[test]
fn nothing_is_accepted_before_allow() {
    let r = Rig::new();
    let (answer, rx) = channel();
    *r.host.hold_answer.lock().unwrap() = Some(rx);
    let mut p = r.phone();
    p.hello("phone-1", "");
    wait_for(|| r.host.asked.load(Ordering::SeqCst) == 1, "the question");
    p.drag("d", &["a.jpg"]);
    p.send(json!({"t": "pair", "state": "ping"}));
    p.send(json!({"t": "pair", "state": "hold", "p": 0.5}));
    answer.send(true).unwrap();
    let m = p.msg();
    assert_eq!(m["t"], "welcome", "no pong, no error before welcome: {m}");
    assert!(r.cues.try_recv().is_err(), "no overlay for a stranger");
}

#[test]
fn a_second_connection_from_a_phone_being_asked_about_is_turned_away() {
    let r = Rig::new();
    let (answer, rx) = channel();
    *r.host.hold_answer.lock().unwrap() = Some(rx);
    let mut a = r.phone();
    a.hello("phone-1", "");
    wait_for(|| r.host.asked.load(Ordering::SeqCst) == 1, "the question");
    let mut b = r.phone();
    b.hello("phone-1", "");
    assert!(b.closed());
    answer.send(true).unwrap();
    a.expect("welcome");
}

#[test]
fn a_phone_that_leaves_during_the_question_is_not_trusted() {
    let r = Rig::new();
    let (_answer, rx) = channel();
    *r.host.hold_answer.lock().unwrap() = Some(rx);
    let mut p = r.phone();
    p.hello("phone-1", "");
    wait_for(|| r.host.asked.load(Ordering::SeqCst) == 1, "the question");
    drop(p);
    wait_for(|| r.srv.ticket().is_none() && r.host.phones.lock().unwrap().is_empty(), "the phone to go");
    let trust = r.dir.path().join("data/trust.json");
    std::thread::sleep(Duration::from_millis(50));
    assert!(!trust.exists());
}

#[test]
fn a_ticket_that_comes_later_reaches_connected_phones() {
    let r = Rig::new();
    let mut p = r.paired("phone-1");
    r.srv.set_ticket("endpointlater".into());
    assert_eq!(p.expect("ticket")["ticket"], "endpointlater");
}

#[test]
fn the_same_window_on_a_newer_path_replaces_the_old_one_but_share_does_not() {
    let r = Rig::new();
    let mut a = r.phone();
    a.hello_as("phone-1", "", "main");
    let token = a.expect("welcome")["token"].as_str().unwrap().to_string();

    let mut share = r.phone();
    share.hello_as("phone-1", &token, "share");
    share.expect("welcome");
    assert_eq!(*r.host.phones.lock().unwrap(), vec!["Galaxy S24"], "one phone, two windows");

    let mut b = r.phone();
    b.hello_as("phone-1", &token, "main");
    b.expect("welcome");
    assert!(a.closed());
    b.send(json!({"t": "pair", "state": "ping"}));
    assert_eq!(b.expect("pair")["state"], "pong");
    share.send(json!({"t": "pair", "state": "ping"}));
    assert_eq!(share.expect("pair")["state"], "pong");
}

#[test]
fn a_bad_frame_length_ends_only_that_connection() {
    let r = Rig::new();
    let mut good = r.paired("phone-1");
    let mut bad = r.paired("phone-2");
    bad.s.write_all(&u32::MAX.to_be_bytes()).unwrap();
    assert!(bad.closed());
    good.send(json!({"t": "pair", "state": "ping"}));
    assert_eq!(good.expect("pair")["state"], "pong");
}

// ---------- connect ceremony

#[test]
fn ping_gets_pong_at_once_even_during_a_drag_and_hold_burst_cancel_reach_the_overlay() {
    let r = Rig::new();
    let mut p = r.paired("phone-1");
    p.send(json!({"t": "pair", "state": "hold", "p": 0.4}));
    match r.next_cue(|c| matches!(c, Cue::PairHold { .. })) {
        Cue::PairHold { p: held, seam } => {
            assert_eq!(held, 0.4);
            assert_eq!(seam, Edge::Right);
        }
        _ => unreachable!(),
    }
    let t = Instant::now();
    p.send(json!({"t": "pair", "state": "ping"}));
    assert_eq!(p.expect("pair")["state"], "pong");
    assert!(t.elapsed() < Duration::from_millis(100), "pong took {:?}", t.elapsed());
    p.send(json!({"t": "pair", "state": "burst"}));
    r.next_cue(|c| matches!(c, Cue::PairBurst));
    p.send(json!({"t": "pair", "state": "cancel"}));
    r.next_cue(|c| matches!(c, Cue::PairCancel));

    p.drag("d", &["a.jpg"]);
    r.next_cue(|c| matches!(c, Cue::DragStart { .. }));
    p.send(json!({"t": "pair", "state": "ping"}));
    assert_eq!(p.expect("pair")["state"], "pong");
    p.send(json!({"t": "pair", "state": "burst"}));
    p.send(json!({"t": "drag_end", "id": "d", "commit": false}));
    let c = r.next_cue(|c| !matches!(c, Cue::DragMove { .. }));
    assert!(matches!(c, Cue::Retract), "the ceremony stays out of a running drag: {c:?}");
}

// ---------- phone → computer

#[test]
fn one_file_arrives_whole_and_the_edge_is_learned() {
    let r = Rig::new();
    let mut p = r.paired("phone-1");
    p.drag("d1", &["IMG_1.jpg"]);
    match r.next_cue(|c| matches!(c, Cue::DragStart { .. })) {
        Cue::DragStart { image, tile_mm, phone_mm, count, .. } => {
            assert_eq!(image.map(|i| (i.w, i.h)), Some((40, 20)));
            assert_eq!(tile_mm, Some(35.5));
            assert_eq!(phone_mm, Some((68.0, 148.0)));
            assert_eq!(count, 1);
        }
        _ => unreachable!(),
    }
    p.move_to("d1", "top", 0.42, 0.25);
    match r.next_cue(|c| matches!(c, Cue::DragMove { .. })) {
        Cue::DragMove { phone_edge, overhang, along } => {
            assert_eq!(phone_edge, Edge::Top);
            assert_eq!((overhang, along), (0.25, 0.42));
        }
        _ => unreachable!(),
    }
    p.move_to("other", "left", 0.1, 0.9); // a stale id moves nothing
    p.commit("d1");
    r.next_cue(|c| matches!(c, Cue::Settle));
    let body = data(700_000);
    p.file("d1", 0, &body);
    let m = p.expect("saved");
    assert_eq!(m["id"], "d1");
    assert_eq!(m["index"], 0);
    assert_eq!(fs::read(saved_path(&m)).unwrap(), body);
    assert_eq!(saved_path(&m).file_name().unwrap(), "IMG_1.jpg");
    r.next_cue(|c| matches!(c, Cue::Land));
    assert_eq!(r.next_note(|n| matches!(n, Note::Saved(_))), Note::Saved(vec![saved_path(&m)]));
    assert_eq!(r.srv.edge(), Edge::Bottom);
    assert_eq!(only_entries(&r.saved_dir()), vec!["IMG_1.jpg"], "no partial left behind");

    // and the learned edge goes out on the next welcome
    let mut q = r.phone();
    q.hello("phone-2", "");
    assert_eq!(q.expect("welcome")["edge"], "bottom");
}

#[test]
fn an_empty_file_is_still_a_file() {
    let r = Rig::new();
    let mut p = r.paired("phone-1");
    p.drag("d", &["empty.txt"]);
    p.commit("d");
    p.file("d", 0, b"");
    assert_eq!(fs::read(saved_path(&p.expect("saved"))).unwrap(), b"");
}

#[test]
fn several_files_go_one_by_one_with_index_and_land_once() {
    let r = Rig::new();
    let mut p = r.paired("phone-1");
    p.drag("d", &["a.jpg", "b.png", "c.mp4"]);
    match r.next_cue(|c| matches!(c, Cue::DragStart { .. })) {
        Cue::DragStart { count, .. } => assert_eq!(count, 3),
        _ => unreachable!(),
    }
    p.commit("d");
    for (i, n) in ["a.jpg", "b.png", "c.mp4"].iter().enumerate() {
        let body = data(1000 * (i + 1));
        p.file("d", i as u64, &body);
        let m = p.expect("saved");
        assert_eq!(m["index"], i as u64);
        assert_eq!(saved_path(&m).file_name().unwrap().to_string_lossy(), *n);
        assert_eq!(fs::read(saved_path(&m)).unwrap(), body);
    }
    r.next_cue(|c| matches!(c, Cue::Land));
    match r.next_note(|n| matches!(n, Note::Saved(_))) {
        Note::Saved(v) => assert_eq!(v.len(), 3),
        _ => unreachable!(),
    }
    assert!(r.cues.try_recv().map_or(true, |c| !matches!(c, Cue::Land)));
}

#[test]
fn collisions_and_hostile_names_stay_inside_the_folder() {
    let r = Rig::new();
    let mut p = r.paired("phone-1");
    let names = ["same.jpg", "same.jpg", "..\\..\\evil.bat", "../evil.bat", "NUL.txt", "a:b.txt"];
    p.drag("d", &names);
    p.commit("d");
    for (i, _) in names.iter().enumerate() {
        p.file("d", i as u64, b"x");
        assert!(saved_path(&p.expect("saved")).starts_with(r.saved_dir()));
    }
    assert_eq!(only_entries(&r.saved_dir()), vec!["_NUL.txt", "a_b.txt", "evil (1).bat", "evil.bat", "same (1).jpg", "same.jpg"]);
    assert_eq!(only_entries(r.dir.path().join("Downloads").as_path()), vec!["lidrop"]);
}

#[test]
fn a_cancelled_drag_saves_nothing_and_frees_the_stage() {
    let r = Rig::new();
    let mut a = r.paired("phone-1");
    let mut b = r.paired("phone-2");
    a.drag("x", &["a.jpg"]);
    r.next_cue(|c| matches!(c, Cue::DragStart { .. }));
    a.send(json!({"t": "drag_end", "id": "x", "commit": false}));
    r.next_cue(|c| matches!(c, Cue::Retract));
    a.send(json!({"t": "file_begin", "id": "x", "index": 0}));
    a.raw(CHUNK, b"late");
    a.send(json!({"t": "file_end", "id": "x", "index": 0}));
    b.drag("y", &["b.jpg"]);
    r.next_cue(|c| matches!(c, Cue::DragStart { .. }));
    assert!(only_entries(&r.saved_dir()).is_empty());
}

#[test]
fn a_second_phone_gets_busy_while_one_drags() {
    let r = Rig::new();
    let mut a = r.paired("phone-1");
    let mut b = r.paired("phone-2");
    a.drag("x", &["a.jpg"]);
    r.next_cue(|c| matches!(c, Cue::DragStart { .. }));
    b.drag("y", &["b.jpg"]);
    let e = b.expect("error");
    assert_eq!((e["id"].as_str(), e["msg"].as_str()), (Some("y"), Some("busy")));
    assert!(!r.srv.can_send());
}

#[test]
fn a_phone_that_vanishes_mid_transfer_leaves_no_partial_and_no_tile() {
    let r = Rig::new();
    let mut p = r.paired("phone-1");
    p.drag("d", &["big.bin"]);
    p.commit("d");
    p.send(json!({"t": "file_begin", "id": "d", "index": 0}));
    p.raw(CHUNK, &data(5000));
    wait_for(|| only_entries(&r.saved_dir()).len() == 1, "the partial file");
    drop(p);
    r.next_cue(|c| matches!(c, Cue::Cancel));
    wait_for(|| only_entries(&r.saved_dir()).is_empty(), "the partial to go");
    let mut q = r.paired("phone-2");
    q.drag("e", &["b.jpg"]);
    r.next_cue(|c| matches!(c, Cue::DragStart { .. }));
}

#[test]
fn saving_into_a_folder_that_cannot_exist_reports_an_error_and_frees_the_stage() {
    let r = Rig::new();
    let mut p = r.paired("phone-1");
    fs::create_dir_all(r.dir.path().join("Downloads")).unwrap();
    fs::write(r.saved_dir(), b"a file where the folder should be").unwrap();
    p.drag("d", &["a.jpg"]);
    p.commit("d");
    p.send(json!({"t": "file_begin", "id": "d", "index": 0}));
    assert!(p.expect("error")["msg"].is_string());
    r.next_cue(|c| matches!(c, Cue::Retract));
    p.drag("e", &["b.jpg"]);
    r.next_cue(|c| matches!(c, Cue::DragStart { .. }));
}

// ---------- video blocks

#[test]
fn a_video_lands_at_once_and_is_saved_whole_from_blocks_in_any_order() {
    let r = Rig::new();
    let mut p = r.paired("phone-1");
    let body = data(CHUNK_SIZE * 2 + 1234);
    p.drag("v", &["clip.mp4"]);
    p.commit("v");
    p.send(json!({"t": "file_begin", "id": "v", "index": 0, "stream": true, "size": body.len(), "mime": "video/mp4"}));
    r.next_cue(|c| matches!(c, Cue::Land));
    p.block(2, &body[CHUNK_SIZE * 2..]);
    p.block(0, &body[..CHUNK_SIZE]);
    p.block(0, &body[..CHUNK_SIZE]); // a seek may resend one
    p.block(1, &body[CHUNK_SIZE..CHUNK_SIZE * 2]);
    p.block(9, b"past the end is ignored");
    p.send(json!({"t": "file_end", "id": "v", "index": 0}));
    let m = p.expect("saved");
    assert_eq!(saved_path(&m).file_name().unwrap(), "clip.mp4");
    assert_eq!(fs::read(saved_path(&m)).unwrap(), body);
    r.next_note(|n| *n == Note::Progress(Some(100)));
    assert_eq!(only_entries(&r.saved_dir()), vec!["clip.mp4"]);
}

#[test]
fn a_video_with_a_missing_block_is_an_error_not_a_broken_file() {
    let r = Rig::new();
    let mut p = r.paired("phone-1");
    let body = data(CHUNK_SIZE + 10);
    p.drag("v", &["clip.mp4"]);
    p.commit("v");
    p.send(json!({"t": "file_begin", "id": "v", "index": 0, "stream": true, "size": body.len(), "mime": "video/mp4"}));
    p.block(0, &body[..CHUNK_SIZE]);
    p.send(json!({"t": "file_end", "id": "v", "index": 0}));
    assert_eq!(p.expect("error")["id"], "v");
    assert!(only_entries(&r.saved_dir()).is_empty());
}

// ---------- the edge zone's handoff, in the orders the threads can really run in

fn one_file(r: &Rig) -> Vec<PathBuf> {
    let file = r.dir.path().join("a.txt");
    fs::write(&file, b"hello").unwrap();
    vec![file]
}

#[test]
fn a_drop_after_the_drag_is_live_commits_once_and_the_late_button_up_changes_nothing() {
    let r = Rig::new();
    let mut p = r.paired("phone-1");
    let h = Handoff::new(r.srv.clone());
    h.begin(one_file(&r), |_| "dGh1bWI=".into());
    assert!(h.accepting());
    let id = p.expect("mdrag_start")["id"].as_str().unwrap().to_string();
    h.moved(0.3, 0.9);
    assert_eq!(p.expect("mdrag_move")["overhang"], 0.9);
    h.finish(true);
    h.finish(false);
    assert!(!h.accepting());
    assert_eq!(p.expect("mdrag_end")["commit"], true);
    assert_eq!(receive_file(&mut p, &id), b"hello");
}

#[test]
fn a_drop_before_the_thumbnail_is_ready_still_commits_and_the_button_up_cannot_undo_it() {
    let r = Rig::new();
    let mut p = r.paired("phone-1");
    let h = Handoff::new(r.srv.clone());
    let (go, wait) = channel::<()>();
    h.begin(one_file(&r), move |_| {
        let _ = wait.recv();
        String::new()
    });
    h.finish(true);
    h.finish(false);
    go.send(()).unwrap();
    let id = p.expect("mdrag_start")["id"].as_str().unwrap().to_string();
    assert_eq!(p.expect("mdrag_end")["commit"], true);
    assert_eq!(receive_file(&mut p, &id), b"hello");
}

#[test]
fn a_release_elsewhere_before_the_thumbnail_is_ready_cancels() {
    let r = Rig::new();
    let mut p = r.paired("phone-1");
    let h = Handoff::new(r.srv.clone());
    let (go, wait) = channel::<()>();
    h.begin(one_file(&r), move |_| {
        let _ = wait.recv();
        String::new()
    });
    h.finish(false);
    go.send(()).unwrap();
    p.expect("mdrag_start");
    assert_eq!(p.expect("mdrag_end")["commit"], false);
    wait_for(|| r.srv.can_send(), "the stage to free");
}

#[test]
fn entering_the_zone_twice_starts_one_drag() {
    let r = Rig::new();
    let mut p = r.paired("phone-1");
    let h = Handoff::new(r.srv.clone());
    h.begin(one_file(&r), |_| String::new());
    p.expect("mdrag_start");
    h.begin(one_file(&r), |_| String::new());
    h.moved(0.5, 0.5);
    let m = p.msg();
    assert_eq!(m["t"], "mdrag_move", "no second start: {m}");
    h.finish(false);
}

#[test]
fn a_drag_the_server_refuses_stops_being_accepted() {
    let r = Rig::new();
    let h = Handoff::new(r.srv.clone()); // no phone at all
    h.begin(one_file(&r), |_| String::new());
    wait_for(|| !h.accepting(), "the refusal");
    h.finish(true);
    h.moved(0.5, 1.0);
}

// ---------- computer → phone

fn start_out(r: &Rig, paths: Vec<PathBuf>) -> lidrop_core::send::OutDrag {
    r.srv.out_start(paths, "dGh1bWI=".into()).expect("drag started")
}

/// What `Receiver.kt` does with a commit: collect the frames of one file until file_end.
fn receive_file(p: &mut Phone, id: &str) -> Vec<u8> {
    assert_eq!(p.expect("file_begin")["id"], id);
    let mut got = Vec::new();
    loop {
        let (kind, b) = p.frame().expect("frame");
        if kind == CHUNK {
            assert!(b.len() <= CHUNK_SIZE);
            got.extend_from_slice(&b);
        } else {
            let m: Value = serde_json::from_slice(&b).unwrap();
            assert_eq!(m["t"], "file_end");
            return got;
        }
    }
}

#[test]
fn one_file_goes_to_the_phone_as_it_is() {
    let r = Rig::new();
    let mut p = r.paired("phone-1");
    let file = r.dir.path().join("report.pdf");
    let body = data(CHUNK_SIZE * 2 + 5);
    fs::write(&file, &body).unwrap();

    assert!(r.srv.can_send());
    let d = start_out(&r, vec![file]);
    let s = p.expect("mdrag_start");
    let id = s["id"].as_str().unwrap().to_string();
    assert_eq!((s["name"].as_str(), s["mime"].as_str()), (Some("report.pdf"), Some("application/pdf")));
    assert_eq!(s["size"], body.len());
    assert_eq!(s["edge"], "right");
    assert_eq!(s["files"][0]["size"], body.len(), "Receiver.kt checks the size against this");
    assert_eq!(s["count"], 1);
    assert_eq!(s["thumb"], "dGh1bWI=");
    assert!(!r.srv.can_send(), "one drag at a time");

    d.moved(0.42, 0.5);
    let m = p.expect("mdrag_move");
    assert_eq!((m["id"].as_str(), m["along"].as_f64(), m["overhang"].as_f64()), (Some(id.as_str()), Some(0.42), Some(0.5)));
    r.next_cue(|c| matches!(c, Cue::OutMove { .. }));

    d.end(true);
    let e = p.expect("mdrag_end");
    assert_eq!(e["commit"], true);
    assert_eq!(receive_file(&mut p, &id), body);
    p.send(json!({"t": "saved", "id": id, "index": 0, "path": "/storage/emulated/0/Download/lidrop/report.pdf"}));
    assert_eq!(
        r.next_note(|n| matches!(n, Note::Sent { .. })),
        Note::Sent { name: "report.pdf".into(), phone: "Galaxy S24".into() }
    );
    wait_for(|| r.srv.can_send(), "the drag to end");
}

#[test]
fn a_cancelled_drag_to_the_phone_sends_no_file() {
    let r = Rig::new();
    let mut p = r.paired("phone-1");
    let file = r.dir.path().join("a.txt");
    fs::write(&file, b"x").unwrap();
    let d = start_out(&r, vec![file]);
    p.expect("mdrag_start");
    d.end(false);
    assert_eq!(p.expect("mdrag_end")["commit"], false);
    assert!(r.srv.can_send());
    p.send(json!({"t": "pair", "state": "ping"}));
    let m = p.msg();
    assert_eq!(m["state"], "pong", "no file_begin in between: {m}");
}

fn zip_entries(bytes: Vec<u8>) -> Vec<(String, Vec<u8>)> {
    let mut z = zip::ZipArchive::new(std::io::Cursor::new(bytes)).unwrap();
    let mut out = Vec::new();
    for i in 0..z.len() {
        let mut f = z.by_index(i).unwrap();
        let mut b = Vec::new();
        f.read_to_end(&mut b).unwrap();
        out.push((f.name().to_string(), b));
    }
    out.sort();
    out
}

#[test]
fn a_folder_goes_as_one_zip_of_unknown_size() {
    let r = Rig::new();
    let mut p = r.paired("phone-1");
    let dir = r.dir.path().join("Holiday");
    fs::create_dir_all(dir.join("day 1")).unwrap();
    fs::write(dir.join("day 1/a.jpg"), data(3000)).unwrap();
    fs::write(dir.join("b.txt"), b"hello").unwrap();

    let d = start_out(&r, vec![dir]);
    let s = p.expect("mdrag_start");
    let id = s["id"].as_str().unwrap().to_string();
    assert_eq!((s["name"].as_str(), s["mime"].as_str()), (Some("Holiday.zip"), Some("application/zip")));
    assert_eq!(s["files"][0]["size"], -1, "Receiver.kt only checks sizes that are not negative");
    d.end(true);
    let zipped = receive_file(&mut p, &id);
    let e = zip_entries(zipped);
    let names: Vec<&str> = e.iter().map(|x| x.0.as_str()).collect();
    assert_eq!(names, vec!["Holiday/", "Holiday/b.txt", "Holiday/day 1/", "Holiday/day 1/a.jpg"]);
    assert_eq!(e[3].1, data(3000));
}

#[test]
fn several_files_go_as_archive_zip_and_same_names_both_survive() {
    let r = Rig::new();
    let mut p = r.paired("phone-1");
    let a = r.dir.path().join("one/same.txt");
    let b = r.dir.path().join("two/same.txt");
    fs::create_dir_all(a.parent().unwrap()).unwrap();
    fs::create_dir_all(b.parent().unwrap()).unwrap();
    fs::write(&a, b"first").unwrap();
    fs::write(&b, b"second").unwrap();
    let d = start_out(&r, vec![a, b]);
    let s = p.expect("mdrag_start");
    assert_eq!(s["name"], "Archive.zip");
    let id = s["id"].as_str().unwrap().to_string();
    d.end(true);
    let e = zip_entries(receive_file(&mut p, &id));
    assert_eq!(e[0], ("Archive/1-same.txt".to_string(), b"second".to_vec()));
    assert_eq!(e[1], ("Archive/same.txt".to_string(), b"first".to_vec()));
}

#[test]
fn a_file_that_cannot_be_read_tells_the_phone_so_its_tile_does_not_wait() {
    let r = Rig::new();
    let mut p = r.paired("phone-1");
    let d = start_out(&r, vec![r.dir.path().join("deleted-meanwhile.txt")]);
    let id = p.expect("mdrag_start")["id"].as_str().unwrap().to_string();
    d.end(true);
    assert_eq!(p.expect("error")["id"], id.as_str());
    r.next_note(|n| matches!(n, Note::SendFailed { .. }));
    wait_for(|| r.srv.can_send(), "the drag to end");
}

#[test]
fn a_phone_error_stops_the_transfer() {
    let r = Rig::new();
    let mut p = r.paired("phone-1");
    let file = r.dir.path().join("big.bin");
    fs::write(&file, vec![1u8; CHUNK_SIZE * 300]).unwrap(); // far more than the socket buffers hold
    let d = start_out(&r, vec![file]);
    let id = p.expect("mdrag_start")["id"].as_str().unwrap().to_string();
    d.end(true);
    p.expect("file_begin");
    p.send(json!({"t": "error", "id": id, "msg": "phone busy"}));
    r.next_note(|n| matches!(n, Note::SendFailed { .. }));
    let end = Instant::now() + WAIT;
    while !r.srv.can_send() {
        assert!(Instant::now() < end, "transfer did not stop");
        let _ = p.frame(); // keep draining so the sender can notice
    }
}

#[test]
fn the_phone_vanishing_mid_send_frees_the_stage() {
    let r = Rig::new();
    let mut p = r.paired("phone-1");
    let file = r.dir.path().join("big.bin");
    fs::write(&file, vec![1u8; CHUNK_SIZE * 300]).unwrap();
    let d = start_out(&r, vec![file]);
    p.expect("mdrag_start");
    d.end(true);
    p.expect("file_begin");
    drop(p);
    let mut q = r.paired("phone-2");
    wait_for(|| r.srv.can_send(), "the send to stop");
    q.send(json!({"t": "pair", "state": "ping"}));
    assert_eq!(q.expect("pair")["state"], "pong");
}

#[test]
fn drags_in_both_directions_never_overlap() {
    let r = Rig::new();
    let mut p = r.paired("phone-1");
    let file = r.dir.path().join("a.txt");
    fs::write(&file, b"x").unwrap();

    let d = start_out(&r, vec![file.clone()]);
    p.expect("mdrag_start");
    assert!(r.srv.out_start(vec![file.clone()], String::new()).is_none());
    p.drag("incoming", &["b.jpg"]);
    assert_eq!(p.expect("error")["msg"], "busy");
    d.end(false);

    p.drag("incoming2", &["b.jpg"]);
    r.next_cue(|c| matches!(c, Cue::DragStart { .. }));
    assert!(r.srv.out_start(vec![file], String::new()).is_none());
    assert!(!r.srv.can_send());
}

#[test]
fn the_target_is_the_last_phone_that_dragged_and_never_a_share_window() {
    let r = Rig::new();
    let mut a = r.paired("phone-1");
    let mut b = r.paired("phone-2");
    let mut share = r.phone();
    share.hello_as("phone-3", "", "share");
    share.expect("welcome");
    let file = r.dir.path().join("a.txt");
    fs::write(&file, b"x").unwrap();

    // most recently connected app first
    start_out(&r, vec![file.clone()]).end(false);
    b.expect("mdrag_start");

    a.drag("x", &["a.jpg"]);
    a.send(json!({"t": "drag_end", "id": "x", "commit": false}));
    r.next_cue(|c| matches!(c, Cue::Retract));
    start_out(&r, vec![file]).end(false);
    a.expect("mdrag_start");
}

#[test]
fn nothing_can_be_sent_with_no_phone_here() {
    let r = Rig::new();
    let file = r.dir.path().join("a.txt");
    fs::write(&file, b"x").unwrap();
    assert!(!r.srv.can_send());
    assert!(r.srv.out_start(vec![file], String::new()).is_none());
    let mut stranger = r.phone();
    stranger.send(json!({"t": "pair", "state": "ping"}));
    std::thread::sleep(Duration::from_millis(50));
    assert!(!r.srv.can_send(), "a connection that has not been allowed is not a target");
}
