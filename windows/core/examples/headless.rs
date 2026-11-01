//! The core with no windows: a stand-in for lidrop.exe that a fake phone can talk to on any OS.
//! `headless [--port N] [--dir DIR] [--deny] [--dumbpipe PATH] [--name NAME] [--mdns] [--send FILE...]`
//! prints one JSON line per thing the Windows app would have shown. `--send` starts a drag to the first phone.
use lidrop_core::server::{Config, Cue, Host, Note, Server};
use lidrop_core::{discovery, tunnel::Tunnel};
use serde_json::json;
use std::path::PathBuf;
use std::sync::atomic::AtomicBool;
use std::sync::Arc;
use std::time::Duration;

struct Print {
    name: String,
    allow: bool,
}

impl Host for Print {
    fn device_name(&self) -> String {
        self.name.clone()
    }
    fn screen_mm(&self) -> Option<(f64, f64)> {
        Some((510.0, 287.0))
    }
    fn ask_allow(&self, phone: &str, _: &AtomicBool) -> bool {
        println!("{}", json!({"ask": phone, "allow": self.allow}));
        self.allow
    }
    fn cue(&self, c: Cue) {
        println!("{}", json!({"cue": format!("{c:?}")}));
    }
    fn phones(&self, names: Vec<String>) {
        println!("{}", json!({"phones": names}));
    }
    fn note(&self, n: Note) {
        println!("{}", json!({"note": format!("{n:?}")}));
    }
}

fn main() {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let opt = |k: &str| args.iter().position(|a| a == k).and_then(|i| args.get(i + 1)).cloned();
    let has = |k: &str| args.iter().any(|a| a == k);
    let dir = opt("--dir").map(PathBuf::from).unwrap_or_else(|| std::env::temp_dir().join("lidrop-headless"));
    let port = opt("--port").and_then(|p| p.parse().ok()).unwrap_or(7777);
    let name = opt("--name").unwrap_or_else(|| "Headless PC".into());
    let host = Arc::new(Print { name: name.clone(), allow: !has("--deny") });
    let cfg = Config { data_dir: dir.join("data"), save_dir: dir.join("Downloads/lidrop"), port };
    let srv = Server::new(host, cfg).expect("data folder");
    let port = srv.start().expect("listen");
    println!("{}", json!({"listening": port}));
    let _mdns = has("--mdns").then(|| discovery::advertise(&name, port).expect("mdns"));
    let _tunnel = opt("--dumbpipe").map(|bin| {
        let s = srv.clone();
        Tunnel::start(PathBuf::from(bin), port, &dir.join("data/tunnel.key"), move |t| {
            println!("{}", json!({"ticket": t}));
            s.set_ticket(t);
        }, |_| {})
    });
    if let Some(at) = args.iter().position(|a| a == "--send") {
        let files: Vec<PathBuf> = args[at + 1..].iter().map(PathBuf::from).collect();
        while !srv.can_send() {
            std::thread::sleep(Duration::from_millis(20));
        }
        let d = srv.out_start(files, String::new()).expect("drag");
        for i in 0..=10 {
            d.moved(0.4, i as f64 / 10.0);
            std::thread::sleep(Duration::from_millis(16));
        }
        d.end(true);
    }
    loop {
        std::thread::sleep(Duration::from_secs(3600));
    }
}
