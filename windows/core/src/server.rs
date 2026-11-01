//! TCP listener and the receiving half of docs/PROTOCOL.md. One thread per phone; everything the phones share
//! (who is dragging, who is connected) sits behind one lock, held only for moments.
use crate::frame::{self, BLOCK, CHUNK, CONTROL};
use crate::receive::{Partial, StreamFile};
use crate::render::Image;
use crate::store::{self, Settings, Trust};
use crate::{render, send};
use serde_json::{json, Value};
use socket2::{Domain, Protocol, Socket, Type};
use std::collections::HashSet;
use std::io::{self, BufReader, Write};
use std::net::{Ipv4Addr, Ipv6Addr, Shutdown, SocketAddr, TcpListener, TcpStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::{Arc, Mutex, MutexGuard};
use std::thread;
use std::time::Duration;

/// A phone that stops reading must not hang whoever is writing to it.
const WRITE_TIMEOUT: Duration = Duration::from_secs(20);

#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Edge {
    Left,
    Right,
    Top,
    Bottom,
}

impl Edge {
    pub fn parse(s: &str) -> Option<Edge> {
        match s {
            "left" => Some(Edge::Left),
            "right" => Some(Edge::Right),
            "top" => Some(Edge::Top),
            "bottom" => Some(Edge::Bottom),
            _ => None,
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Edge::Left => "left",
            Edge::Right => "right",
            Edge::Top => "top",
            Edge::Bottom => "bottom",
        }
    }

    pub fn opposite(self) -> Edge {
        match self {
            Edge::Left => Edge::Right,
            Edge::Right => Edge::Left,
            Edge::Top => Edge::Bottom,
            Edge::Bottom => Edge::Top,
        }
    }

    pub fn vertical(self) -> bool {
        matches!(self, Edge::Left | Edge::Right)
    }
}

/// What the overlay should show. `stage::Stage` turns these into frames.
#[derive(Debug)]
pub enum Cue {
    DragStart { image: Option<Image>, tile_dp: f64, tile_mm: Option<f64>, phone_mm: Option<(f64, f64)>, count: usize },
    DragMove { phone_edge: Edge, overhang: f64, along: f64 },
    Settle,
    Retract,
    Land,
    Cancel,
    PairHold { p: f64, seam: Edge },
    PairBurst,
    PairCancel,
    OutMove { edge: Edge, overhang: f64, along: f64 },
    OutEnd { commit: bool },
}

/// Things worth telling the user outside the overlay.
#[derive(Debug, PartialEq)]
pub enum Note {
    Saved(Vec<PathBuf>),
    Progress(Option<u32>),
    Sent { name: String, phone: String },
    SendFailed { msg: String },
}

/// The computer around the protocol: the Win32 shell in the app, a recorder in the tests.
pub trait Host: Send + Sync + 'static {
    fn device_name(&self) -> String;
    fn screen_mm(&self) -> Option<(f64, f64)>;
    /// Blocks until the user answers. `gone` turns true if the phone leaves meanwhile, so the question can go away.
    fn ask_allow(&self, phone: &str, gone: &AtomicBool) -> bool;
    fn cue(&self, c: Cue);
    fn phones(&self, names: Vec<String>);
    fn note(&self, n: Note);
}

pub struct Config {
    pub data_dir: PathBuf,
    pub save_dir: PathBuf,
    pub port: u16,
}

pub(crate) fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner()) // one panicked connection must not take the others down
}

/// One connected phone. The app and its Share window are separate connections from one phone.
pub struct Phone {
    pub(crate) uid: u64,
    writer: Mutex<TcpStream>,
    pub(crate) name: Mutex<String>,
    id: Mutex<Option<String>>,
    role: Mutex<String>,
    gone: Arc<AtomicBool>,
    /// id of the computer → phone transfer heading here, and whether the phone gave up on it
    pub(crate) out_id: Mutex<Option<String>>,
    pub(crate) out_stop: AtomicBool,
}

impl Phone {
    pub(crate) fn send_frame(&self, kind: u8, payload: &[u8]) -> io::Result<()> {
        let mut w = lock(&self.writer);
        let r = w.write_all(&frame::encode(kind, payload));
        if r.is_err() {
            let _ = w.shutdown(Shutdown::Both);
        }
        r
    }

    pub(crate) fn send(&self, m: &Value) -> bool {
        self.send_frame(CONTROL, m.to_string().as_bytes()).is_ok()
    }

    fn close(&self) {
        let _ = lock(&self.writer).shutdown(Shutdown::Both);
    }

    fn admitted(&self) -> bool {
        lock(&self.id).is_some()
    }

    fn matches(&self, id: &str, role: &str) -> bool {
        lock(&self.id).as_deref() == Some(id) && *lock(&self.role) == role
    }
}

#[derive(Default)]
pub(crate) struct State {
    phones: Vec<Arc<Phone>>,
    drag_owner: Option<u64>, // phone whose phone → computer drag is running
    pub(crate) out_active: bool, // a computer → phone drag or transfer is running
    last_starter: Option<u64>,
    asking: HashSet<String>,
}

impl State {
    pub(crate) fn busy(&self) -> bool {
        self.drag_owner.is_some() || self.out_active
    }

    /// Computer → phone target: the most recent drag_start, else the most recently connected app.
    /// A Share window is on screen for a moment and cannot receive.
    pub(crate) fn target(&self) -> Option<Arc<Phone>> {
        let can_receive = |p: &&Arc<Phone>| p.admitted() && *lock(&p.role) == "main";
        self.phones
            .iter()
            .filter(can_receive)
            .find(|p| Some(p.uid) == self.last_starter)
            .or_else(|| self.phones.iter().rfind(can_receive))
            .cloned()
    }
}

pub struct Server {
    pub(crate) host: Arc<dyn Host>,
    pub(crate) state: Mutex<State>,
    trust: Mutex<Trust>,
    settings: Mutex<Settings>,
    ticket: Mutex<Option<String>>,
    pub(crate) save_dir: PathBuf,
    port: u16,
    next_uid: AtomicU64,
}

impl Server {
    pub fn new(host: Arc<dyn Host>, cfg: Config) -> io::Result<Arc<Server>> {
        std::fs::create_dir_all(&cfg.data_dir)?;
        store::sweep_partials(&cfg.save_dir);
        Ok(Arc::new(Server {
            host,
            state: Mutex::default(),
            trust: Mutex::new(Trust::load(&cfg.data_dir)),
            settings: Mutex::new(Settings::load(&cfg.data_dir)),
            ticket: Mutex::new(None),
            save_dir: cfg.save_dir,
            port: cfg.port,
            next_uid: AtomicU64::new(1),
        }))
    }

    /// Listens on all interfaces and returns the port. Failing to bind is the caller's to report.
    pub fn start(self: &Arc<Self>) -> io::Result<u16> {
        let l = listen(self.port)?;
        let port = l.local_addr()?.port();
        let me = self.clone();
        thread::spawn(move || {
            for c in l.incoming().flatten() {
                let me = me.clone();
                thread::spawn(move || me.serve(c));
            }
        });
        Ok(port)
    }

    pub fn ticket(&self) -> Option<String> {
        lock(&self.ticket).clone()
    }

    /// The tunnel has its ticket: phones already here get it now.
    pub fn set_ticket(&self, t: String) {
        *lock(&self.ticket) = Some(t.clone());
        let phones = lock(&self.state).phones.clone();
        let m = json!({"t": "ticket", "ticket": t});
        phones.iter().filter(|p| p.admitted()).for_each(|p| {
            p.send(&m);
        });
    }

    pub fn edge(&self) -> Edge {
        lock(&self.settings).edge
    }

    pub fn save_dir(&self) -> &Path {
        &self.save_dir
    }

    /// A computer → phone drag could start right now.
    pub fn can_send(&self) -> bool {
        let s = lock(&self.state);
        !s.busy() && s.target().is_some()
    }

    fn serve(self: Arc<Self>, c: TcpStream) {
        let _ = c.set_nodelay(true);
        let _ = c.set_write_timeout(Some(WRITE_TIMEOUT));
        let Ok(writer) = c.try_clone() else { return };
        let phone = Arc::new(Phone {
            uid: self.next_uid.fetch_add(1, Ordering::Relaxed),
            writer: Mutex::new(writer),
            name: Mutex::new("phone".into()),
            id: Mutex::new(None),
            role: Mutex::new("main".into()),
            gone: Arc::new(AtomicBool::new(false)),
            out_id: Mutex::new(None),
            out_stop: AtomicBool::new(false),
        });
        lock(&self.state).phones.push(phone.clone());
        let mut conn = Conn { srv: self.clone(), p: phone.clone(), rx: Rx::default() };
        let mut r = BufReader::with_capacity(1 << 20, c);
        let mut buf = Vec::new();
        while let Ok(Some(kind)) = frame::read_frame(&mut r, &mut buf) {
            match kind {
                CONTROL => {
                    if let Ok(m) = serde_json::from_slice::<Value>(&buf) {
                        conn.handle(&m);
                    }
                }
                CHUNK => conn.chunk(&buf),
                BLOCK => conn.block(&buf),
                _ => {}
            }
        }
        conn.left();
    }

    fn notify_phones(&self) {
        let phones = lock(&self.state).phones.clone();
        let mut seen = HashSet::new();
        let names = phones
            .iter()
            .filter(|p| lock(&p.id).as_ref().is_some_and(|id| seen.insert(id.clone())))
            .map(|p| lock(&p.name).clone())
            .collect();
        self.host.phones(names);
    }

    fn admit(&self, p: &Arc<Phone>, id: &str, token: Option<String>) {
        let role = lock(&p.role).clone();
        for o in lock(&self.state).phones.iter() {
            if o.uid != p.uid && o.matches(id, &role) {
                o.close(); // the same window on a newer path
            }
        }
        *lock(&p.id) = Some(id.to_string());
        let mut w = json!({"t": "welcome", "name": self.host.device_name(), "edge": self.edge().as_str()});
        if let Some((mm_w, mm_h)) = self.host.screen_mm() {
            w["screen_mm"] = json!([mm_w, mm_h]); // the phone sizes its half of the dome to this
        }
        if let Some(t) = token {
            w["token"] = json!(t);
        }
        if let Some(t) = self.ticket() {
            w["ticket"] = json!(t);
        }
        p.send(&w);
        self.notify_phones();
    }

    /// `hello`: a remembered phone goes straight in; a new one needs Allow once, then never again.
    fn hello(self: &Arc<Self>, m: &Value, p: &Arc<Phone>) {
        // it goes into the Allow dialog and the tray menu
        *lock(&p.name) = m["name"].as_str().unwrap_or("phone").chars().filter(|c| !c.is_control()).take(64).collect();
        *lock(&p.role) = m["role"].as_str().unwrap_or("main").to_string();
        let id = m["id"].as_str().unwrap_or("");
        if id.is_empty() {
            return p.close();
        }
        if lock(&self.trust).valid(id, m["token"].as_str().unwrap_or("")) {
            return self.admit(p, id, None);
        }
        if !lock(&self.state).asking.insert(id.to_string()) {
            return p.close();
        }
        let (me, p, id) = (self.clone(), p.clone(), id.to_string());
        thread::spawn(move || {
            let name = lock(&p.name).clone();
            let ok = me.host.ask_allow(&name, &p.gone);
            lock(&me.state).asking.remove(&id);
            if p.gone.load(Ordering::Acquire) {
                return;
            }
            if ok {
                let token = lock(&me.trust).allow(&id);
                me.admit(&p, &id, Some(token));
            } else {
                p.send(&json!({"t": "denied"}));
                p.close();
            }
        });
    }
}

fn listen(port: u16) -> io::Result<TcpListener> {
    let bind = |domain, addr: SocketAddr, dual: bool| -> io::Result<TcpListener> {
        let s = Socket::new(domain, Type::STREAM, Some(Protocol::TCP))?;
        if dual {
            s.set_only_v6(false)?;
        }
        s.bind(&addr.into())?;
        s.listen(16)?;
        Ok(s.into())
    };
    bind(Domain::IPV6, SocketAddr::from((Ipv6Addr::UNSPECIFIED, port)), true)
        .or_else(|_| bind(Domain::IPV4, SocketAddr::from((Ipv4Addr::UNSPECIFIED, port)), false))
}

/// The current phone → computer drag on one connection.
struct Rx {
    cur: Option<String>,
    names: Vec<String>,
    count: usize,
    committed: bool,
    file: Option<Partial>,
    stream: Option<StreamFile>,
    saved: Vec<PathBuf>,
}

impl Default for Rx {
    fn default() -> Self {
        Rx { cur: None, names: vec!["file".into()], count: 1, committed: false, file: None, stream: None, saved: Vec::new() }
    }
}

struct Conn {
    srv: Arc<Server>,
    p: Arc<Phone>,
    rx: Rx,
}

impl Conn {
    fn owns_drag(&self) -> bool {
        lock(&self.srv.state).drag_owner == Some(self.p.uid)
    }

    fn release_drag(&mut self) {
        self.rx.cur = None;
        let mut s = lock(&self.srv.state);
        if s.drag_owner == Some(self.p.uid) {
            s.drag_owner = None;
        }
    }

    fn abort_transfer(&mut self) {
        self.rx.file = None; // dropping a Partial removes it
        if self.rx.stream.take().is_some() {
            self.srv.host.note(Note::Progress(None));
        }
        self.rx.cur = None;
    }

    /// The transfer cannot finish: tell the phone, take the tile back, keep the connection.
    fn fail(&mut self, id: &str, index: u64, e: impl std::fmt::Display) {
        self.p.send(&json!({"t": "error", "id": id, "index": index, "msg": e.to_string()}));
        self.abort_transfer();
        self.release_drag();
        self.srv.host.cue(Cue::Retract);
    }

    fn chunk(&mut self, d: &[u8]) {
        let Some(f) = self.rx.file.as_mut() else { return };
        if let Err(e) = f.write(d) {
            let id = self.rx.cur.clone().unwrap_or_default();
            self.fail(&id, 0, e);
        }
    }

    fn block(&mut self, d: &[u8]) {
        let Some(st) = self.rx.stream.as_mut() else { return };
        match st.write(d) {
            Ok(Some(pct)) => self.srv.host.note(Note::Progress(Some(pct))),
            Ok(None) => {}
            Err(e) => {
                let id = self.rx.cur.clone().unwrap_or_default();
                self.fail(&id, 0, e);
            }
        }
    }

    fn handle(&mut self, m: &Value) {
        let t = m["t"].as_str().unwrap_or("");
        if t == "hello" {
            if !self.p.admitted() {
                self.srv.hello(m, &self.p);
            }
            return;
        }
        if !self.p.admitted() {
            return; // nothing else is accepted before Allow
        }
        let id = m["id"].as_str();
        let current = id.is_some() && id == self.rx.cur.as_deref();
        let host = self.srv.host.clone();
        match t {
            "saved" | "error" => send::phone_answered(&self.srv, &self.p, t, m),
            "pair" => self.pair(m),
            "drag_start" => self.drag_start(m, id),
            "drag_move" => {
                if !current || !self.owns_drag() {
                    return;
                }
                let phone_edge = m["edge"].as_str().and_then(Edge::parse).unwrap_or(Edge::Left);
                let overhang = m["overhang"].as_f64().unwrap_or(0.0).clamp(0.0, 1.0);
                if overhang > 0.0 {
                    lock(&self.srv.settings).set_edge(phone_edge.opposite());
                }
                host.cue(Cue::DragMove { phone_edge, overhang, along: m["along"].as_f64().unwrap_or(0.5).clamp(0.0, 1.0) });
            }
            "drag_end" => {
                if !current || !self.owns_drag() {
                    return;
                }
                if m["commit"].as_bool() == Some(true) {
                    self.rx.committed = true;
                    host.cue(Cue::Settle);
                } else {
                    host.cue(Cue::Retract);
                    self.release_drag();
                }
            }
            "file_begin" => {
                if current && self.rx.committed {
                    self.file_begin(m);
                }
            }
            "file_end" => {
                if current {
                    self.file_end(m);
                }
            }
            _ => {}
        }
    }

    fn pair(&mut self, m: &Value) {
        let state = m["state"].as_str().unwrap_or("");
        if state == "ping" {
            self.p.send(&json!({"t": "pair", "state": "pong"})); // the phone times the link to start the wave with us
            return;
        }
        if lock(&self.srv.state).busy() {
            return;
        }
        let host = &self.srv.host;
        match state {
            "hold" => host.cue(Cue::PairHold { p: m["p"].as_f64().unwrap_or(0.0).clamp(0.0, 1.0), seam: self.srv.edge() }),
            "burst" => host.cue(Cue::PairBurst),
            _ => host.cue(Cue::PairCancel),
        }
    }

    fn drag_start(&mut self, m: &Value, id: Option<&str>) {
        {
            let mut s = lock(&self.srv.state);
            if s.drag_owner.is_some_and(|o| o != self.p.uid) || s.out_active {
                drop(s);
                self.p.send(&json!({"t": "error", "id": id, "msg": "busy"}));
                return;
            }
            s.drag_owner = Some(self.p.uid);
            s.last_starter = Some(self.p.uid);
        }
        self.abort_transfer();
        let rx = &mut self.rx;
        rx.cur = id.map(str::to_string);
        rx.committed = false;
        rx.saved.clear();
        match m["files"].as_array().filter(|f| !f.is_empty()) {
            Some(fs) => {
                rx.names = fs.iter().map(|f| f["name"].as_str().unwrap_or("file").to_string()).collect();
                rx.count = (m["count"].as_u64().unwrap_or(fs.len() as u64) as usize).max(1);
            }
            None => {
                rx.names = vec![m["name"].as_str().unwrap_or("file").to_string()];
                rx.count = 1;
            }
        }
        let phone_mm = m["screen_mm"].as_array().filter(|a| a.len() == 2).and_then(|a| Some((a[0].as_f64()?, a[1].as_f64()?)));
        self.srv.host.cue(Cue::DragStart {
            image: m["thumb"].as_str().and_then(render::decode_b64),
            tile_dp: m["tile_dp"].as_f64().unwrap_or(96.0),
            tile_mm: m["tile_mm"].as_f64(),
            phone_mm,
            count: rx.count,
        });
    }

    fn file_begin(&mut self, m: &Value) {
        let id = self.rx.cur.clone().unwrap_or_default();
        let index = m["index"].as_u64().unwrap_or(0);
        self.rx.file = None;
        self.rx.stream = None;
        if m["stream"].as_bool() == Some(true) {
            if let Some(size) = m["size"].as_u64().filter(|s| *s > 0) {
                match StreamFile::create(&self.srv.save_dir, size) {
                    Ok(st) => {
                        self.rx.stream = Some(st);
                        self.srv.host.cue(Cue::Land); // a video lands at once; it keeps arriving behind the tile
                    }
                    Err(e) => self.fail(&id, index, e),
                }
                return;
            }
        }
        match Partial::create(&self.srv.save_dir) {
            Ok(f) => self.rx.file = Some(f),
            Err(e) => self.fail(&id, index, e),
        }
    }

    fn name_at(&self, index: usize) -> String {
        self.rx.names.get(index).unwrap_or(&self.rx.names[0]).clone()
    }

    fn file_end(&mut self, m: &Value) {
        let id = self.rx.cur.clone().unwrap_or_default();
        let index = m["index"].as_u64().unwrap_or(0);
        let name = self.name_at(index as usize);
        let srv = self.srv.clone();
        if let Some(st) = self.rx.stream.take() {
            srv.host.note(Note::Progress(None));
            if !st.complete() {
                drop(st); // gone before the phone hears about it
                return self.fail(&id, index, "video incomplete");
            }
            match st.save(&srv.save_dir, &name) {
                Ok(dest) => {
                    self.p.send(&json!({"t": "saved", "id": id, "index": 0, "path": dest.to_string_lossy()}));
                    self.release_drag();
                    srv.host.note(Note::Saved(vec![dest]));
                }
                Err(e) => self.fail(&id, index, e),
            }
            return;
        }
        let Some(f) = self.rx.file.take() else { return };
        match f.save(&srv.save_dir, &name) {
            Ok(dest) => {
                self.p.send(&json!({"t": "saved", "id": id, "index": index, "path": dest.to_string_lossy()}));
                self.rx.saved.push(dest);
                if self.rx.saved.len() >= self.rx.count || index as usize + 1 >= self.rx.count {
                    srv.host.cue(Cue::Land);
                    srv.host.note(Note::Saved(std::mem::take(&mut self.rx.saved)));
                    self.release_drag();
                }
            }
            Err(e) => self.fail(&id, index, e),
        }
    }

    /// The connection is gone, in any way.
    fn left(mut self) {
        self.p.gone.store(true, Ordering::Release);
        self.p.out_stop.store(true, Ordering::Release);
        let was_owner = self.owns_drag();
        {
            let mut s = lock(&self.srv.state);
            s.phones.retain(|o| o.uid != self.p.uid);
        }
        self.abort_transfer();
        self.release_drag();
        if was_owner {
            self.srv.host.cue(Cue::Cancel);
        }
        self.srv.notify_phones();
    }
}
