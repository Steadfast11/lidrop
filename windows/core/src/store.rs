//! What lidrop keeps on disk: phones the user allowed, the learned edge, the tunnel key, and safe file names.
use crate::server::Edge;
use serde_json::{json, Map, Value};
use std::collections::HashMap;
use std::fs;
use std::io;
use std::path::{Path, PathBuf};

pub fn random_hex(n: usize) -> String {
    let mut b = vec![0u8; n];
    getrandom::fill(&mut b).expect("the OS random source");
    b.iter().map(|x| format!("{x:02x}")).collect()
}

/// A UUID-shaped id, like the ones the phones make.
pub fn uuid() -> String {
    let h = random_hex(16);
    format!("{}-{}-{}-{}-{}", &h[..8], &h[8..12], &h[12..16], &h[16..20], &h[20..])
}

fn write_atomic(path: &Path, data: &[u8]) -> io::Result<()> {
    let tmp = path.with_extension("tmp");
    fs::write(&tmp, data)?;
    fs::rename(&tmp, path)
}

/// Phones the user allowed: phone id → token handed out on Allow. Never expires.
pub struct Trust {
    path: PathBuf,
    phones: HashMap<String, String>,
}

impl Trust {
    pub fn load(dir: &Path) -> Self {
        let path = dir.join("trust.json");
        let phones = fs::read(&path).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or_default();
        Trust { path, phones }
    }

    pub fn valid(&self, id: &str, token: &str) -> bool {
        !token.is_empty() && self.phones.get(id).is_some_and(|t| t == token)
    }

    pub fn allow(&mut self, id: &str) -> String {
        let t = random_hex(32);
        self.phones.insert(id.to_string(), t.clone());
        if let Ok(d) = serde_json::to_vec(&self.phones) {
            let _ = write_atomic(&self.path, &d);
        }
        t
    }
}

/// The screen edge that leads to the phone: the entry edge of the last phone → computer drag.
pub struct Settings {
    path: PathBuf,
    pub edge: Edge,
}

impl Settings {
    pub fn load(dir: &Path) -> Self {
        let path = dir.join("settings.json");
        let v: Value = fs::read(&path).ok().and_then(|d| serde_json::from_slice(&d).ok()).unwrap_or(Value::Null);
        let edge = v["edge"].as_str().and_then(Edge::parse).unwrap_or(Edge::Right);
        Settings { path, edge }
    }

    pub fn set_edge(&mut self, e: Edge) {
        if e == self.edge {
            return;
        }
        self.edge = e;
        let mut m = Map::new();
        m.insert("edge".into(), json!(e.as_str()));
        let _ = write_atomic(&self.path, Value::Object(m).to_string().as_bytes());
    }
}

/// The name a phone sent, made safe to create on Windows: one plain component, no stream or device tricks.
pub fn safe_name(name: &str) -> String {
    let base = name.rsplit(['/', '\\']).next().unwrap_or("");
    let mut s: String =
        base.chars().map(|c| if c < ' ' || "<>:\"|?*".contains(c) { '_' } else { c }).collect();
    s.truncate(s.trim_end_matches(['.', ' ']).len());
    if s.is_empty() || s.starts_with('.') {
        s.insert_str(0, "file");
    }
    let device = split_ext(&s).0.split('.').next().unwrap_or("").trim_end().to_ascii_uppercase();
    let numbered = device.len() == 4
        && (device.starts_with("COM") || device.starts_with("LPT"))
        && device.ends_with(|c: char| c.is_ascii_digit());
    if numbered || ["CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$"].contains(&device.as_str()) {
        s.insert(0, '_');
    }
    // NTFS allows 255 UTF-16 units; leave room for " (123)" and stay clear of MAX_PATH in a deep Downloads
    let (stem, ext) = split_ext(&s);
    let mut left = 180usize.saturating_sub(ext.encode_utf16().count());
    let short: String = stem
        .chars()
        .take_while(|c| {
            let fits = c.len_utf16() <= left;
            left = left.saturating_sub(c.len_utf16());
            fits
        })
        .collect();
    short + ext
}

/// (`"IMG_1"`, `".jpg"`); the dot stays with the extension so the two glue back together.
fn split_ext(s: &str) -> (&str, &str) {
    match s.rfind('.') {
        Some(i) if i > 0 => s.split_at(i),
        _ => (s, ""),
    }
}

/// `dir/name`, or `dir/name (1)` etc. on a collision. The empty file it creates holds the name until the rename.
pub fn claim_path(dir: &Path, name: &str) -> io::Result<PathBuf> {
    let safe = safe_name(name);
    let (stem, ext) = split_ext(&safe);
    for i in 0u32.. {
        let p = dir.join(if i == 0 { safe.clone() } else { format!("{stem} ({i}){ext}") });
        match fs::OpenOptions::new().write(true).create_new(true).open(&p) {
            Ok(_) => return Ok(p),
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => continue,
            Err(e) => return Err(e),
        }
    }
    unreachable!()
}

/// A crash mid-transfer leaves its `.partial-*` behind; nothing else may still be writing them at startup.
pub fn sweep_partials(dir: &Path) {
    for e in fs::read_dir(dir).into_iter().flatten().flatten() {
        if e.file_name().to_string_lossy().starts_with(".partial-") {
            let _ = fs::remove_file(e.path());
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_stay_one_plain_component() {
        assert_eq!(safe_name("IMG_1.jpg"), "IMG_1.jpg");
        assert_eq!(safe_name("../../evil.exe"), "evil.exe");
        assert_eq!(safe_name("..\\..\\Windows\\evil.dll"), "evil.dll");
        assert_eq!(safe_name("C:\\Users\\a\\b.txt"), "b.txt");
        assert_eq!(safe_name("a.txt:hidden"), "a.txt_hidden");
        assert_eq!(safe_name("what?.jpg"), "what_.jpg");
        assert_eq!(safe_name("tab\there.txt"), "tab_here.txt");
        assert_eq!(safe_name("dots... "), "dots");
        assert_eq!(safe_name(""), "file");
        assert_eq!(safe_name("..."), "file");
        assert_eq!(safe_name("/"), "file");
        assert_eq!(safe_name(".bashrc"), "file.bashrc");
        assert_eq!(safe_name("фото.jpg"), "фото.jpg");
    }

    #[test]
    fn device_names_cannot_be_reached() {
        for n in ["CON", "con.txt", "NUL.tar.gz", "COM1.jpg", "lpt9", "aux .txt"] {
            assert!(safe_name(n).starts_with('_'), "{n} -> {}", safe_name(n));
        }
        assert_eq!(safe_name("CONTENT.txt"), "CONTENT.txt");
        assert_eq!(safe_name("COM10.txt"), "COM10.txt");
    }

    #[test]
    fn long_names_keep_their_extension() {
        let s = safe_name(&("я".repeat(400) + ".jpeg"));
        assert!(s.ends_with(".jpeg"));
        assert!(s.encode_utf16().count() <= 180);
    }

    #[test]
    fn collisions_count_up_before_the_extension() {
        let d = tempfile::tempdir().unwrap();
        let name = |p: PathBuf| p.file_name().unwrap().to_string_lossy().into_owned();
        assert_eq!(name(claim_path(d.path(), "a.tar.gz").unwrap()), "a.tar.gz");
        assert_eq!(name(claim_path(d.path(), "a.tar.gz").unwrap()), "a.tar (1).gz");
        assert_eq!(name(claim_path(d.path(), "a.tar.gz").unwrap()), "a.tar (2).gz");
        assert_eq!(name(claim_path(d.path(), "noext").unwrap()), "noext");
        assert_eq!(name(claim_path(d.path(), "noext").unwrap()), "noext (1)");
    }

    #[test]
    fn trust_survives_a_restart_and_needs_the_token() {
        let d = tempfile::tempdir().unwrap();
        let token = Trust::load(d.path()).allow("phone");
        let t = Trust::load(d.path());
        assert!(t.valid("phone", &token));
        assert!(!t.valid("phone", "wrong"));
        assert!(!t.valid("phone", ""));
        assert!(!t.valid("other", &token));
    }

    #[test]
    fn the_learned_edge_survives_a_restart() {
        let d = tempfile::tempdir().unwrap();
        assert_eq!(Settings::load(d.path()).edge, Edge::Right);
        Settings::load(d.path()).set_edge(Edge::Top);
        assert_eq!(Settings::load(d.path()).edge, Edge::Top);
    }
}
