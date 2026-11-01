//! Computer → phone: PROTOCOL.md's `mdrag_*` on the same connection. One regular file goes as it is; a folder or
//! several files go as one zip, made on commit. The shell says when the drag starts, moves and ends.
use crate::frame::{CHUNK, CHUNK_SIZE};
use crate::server::{lock, Cue, Edge, Note, Phone, Server};
use crate::store;
use serde_json::{json, Value};
use std::fs::{self, File};
use std::io::{self, Read, Write};
use std::path::{Path, PathBuf};
use std::sync::atomic::Ordering;
use std::sync::Arc;
use std::thread;
use zip::write::SimpleFileOptions;

pub struct OutDrag {
    srv: Arc<Server>,
    phone: Arc<Phone>,
    id: String,
    paths: Vec<PathBuf>,
    name: String,
    edge: Edge,
}

impl Server {
    /// Starts a drag toward the phone with the given files, or `None` if something else is running.
    pub fn out_start(self: &Arc<Self>, paths: Vec<PathBuf>, thumb_b64: String) -> Option<OutDrag> {
        let first = paths.first()?;
        let zip = as_zip(&paths);
        let name = name_for(&paths);
        // the size of a zip is not known until commit; the phone skips its size check for -1
        let size: i64 = if zip { -1 } else { fs::metadata(first).map_or(-1, |m| m.len() as i64) };
        let mime = if zip { "application/zip" } else { mime_for(first) };
        let phone = {
            let mut s = lock(&self.state);
            if s.busy() {
                return None;
            }
            let p = s.target()?;
            s.out_active = true;
            p
        };
        let id = store::uuid();
        let edge = self.edge();
        *lock(&phone.out_id) = Some(id.clone());
        phone.out_stop.store(false, Ordering::Release);
        phone.send(&json!({"t": "mdrag_start", "id": id, "name": name, "mime": mime, "size": size,
            "files": [{"name": name, "size": size, "mime": mime}], "count": 1,
            "thumb": thumb_b64, "tile_mm": 35.5, "edge": edge.as_str()}));
        Some(OutDrag { srv: self.clone(), phone, id, paths, name, edge })
    }
}

impl OutDrag {
    pub fn edge(&self) -> Edge {
        self.edge
    }

    /// `along` = cursor position along the edge in reading direction; `overhang` = how far into the edge zone.
    pub fn moved(&self, along: f64, overhang: f64) {
        self.phone.send(&json!({"t": "mdrag_move", "id": self.id, "along": along, "overhang": overhang}));
        self.srv.host.cue(Cue::OutMove { edge: self.edge, overhang, along });
    }

    /// The button came up. `commit` = it came up on the edge.
    pub fn end(self, commit: bool) {
        self.phone.send(&json!({"t": "mdrag_end", "id": self.id, "commit": commit}));
        self.srv.host.cue(Cue::OutEnd { commit });
        if !commit {
            lock(&self.srv.state).out_active = false;
            *lock(&self.phone.out_id) = None;
            return;
        }
        thread::spawn(move || {
            if let Err(e) = self.transfer() {
                self.phone.send(&json!({"t": "error", "id": self.id, "msg": e.to_string()}));
                self.srv.host.note(Note::SendFailed { msg: e.to_string() });
            }
            lock(&self.srv.state).out_active = false; // only now may another drag use this connection
        });
    }

    fn transfer(&self) -> io::Result<()> {
        let tmp = TempDir::new()?;
        let file = if as_zip(&self.paths) { make_zip(&self.paths, &self.name, &tmp.0)? } else { self.paths[0].clone() };
        let mut f = File::open(&file)?;
        let p = &self.phone;
        p.send(&json!({"t": "file_begin", "id": self.id, "index": 0}));
        let mut buf = vec![0u8; CHUNK_SIZE];
        loop {
            let mut n = 0;
            while n < buf.len() {
                match f.read(&mut buf[n..])? {
                    0 => break,
                    r => n += r,
                }
            }
            if n == 0 {
                break;
            }
            if p.out_stop.load(Ordering::Acquire) {
                return Ok(()); // the phone already said why, or left
            }
            p.send_frame(CHUNK, &buf[..n])?;
        }
        p.send(&json!({"t": "file_end", "id": self.id, "index": 0}));
        Ok(())
    }
}

/// `saved` or `error` from the phone about what we are sending.
pub(crate) fn phone_answered(srv: &Server, p: &Phone, kind: &str, m: &Value) {
    let mut out = lock(&p.out_id);
    if out.is_none() || m["id"].as_str() != out.as_deref() {
        return;
    }
    *out = None;
    drop(out);
    if kind == "saved" {
        let name = m["path"].as_str().unwrap_or("").rsplit('/').next().unwrap_or("file").to_string();
        srv.host.note(Note::Sent { name, phone: lock(&p.name).clone() });
    } else {
        p.out_stop.store(true, Ordering::Release);
        srv.host.note(Note::SendFailed { msg: m["msg"].as_str().unwrap_or("the phone refused it").to_string() });
    }
}

fn as_zip(paths: &[PathBuf]) -> bool {
    paths.len() > 1 || paths.first().is_some_and(|p| p.is_dir())
}

fn leaf(p: &Path) -> String {
    p.file_name().map_or_else(|| "file".to_string(), |n| n.to_string_lossy().into_owned())
}

fn name_for(paths: &[PathBuf]) -> String {
    match paths {
        [one] if one.is_dir() => format!("{}.zip", leaf(one)),
        [one] => leaf(one),
        _ => "Archive.zip".to_string(),
    }
}

/// One folder keeps its name inside the zip; several items sit in an `Archive` folder, like the Mac's.
fn make_zip(paths: &[PathBuf], name: &str, dir: &Path) -> io::Result<PathBuf> {
    let out = dir.join(store::safe_name(name));
    let mut z = zip::ZipWriter::new(File::create(&out)?);
    let root = if paths.len() > 1 { "Archive/" } else { "" };
    let mut used = std::collections::HashSet::new();
    for p in paths {
        let mut entry = format!("{root}{}", leaf(p));
        let mut i = 1;
        while !used.insert(entry.clone()) {
            entry = format!("{root}{i}-{}", leaf(p));
            i += 1;
        }
        add_tree(&mut z, p, &entry)?;
    }
    z.finish().map_err(io::Error::other)?;
    Ok(out)
}

fn add_tree<W: Write + io::Seek>(z: &mut zip::ZipWriter<W>, path: &Path, entry: &str) -> io::Result<()> {
    let meta = fs::symlink_metadata(path)?;
    if meta.file_type().is_symlink() {
        return Ok(()); // links can point anywhere, even back up the tree
    }
    let opts = SimpleFileOptions::default()
        .compression_method(zip::CompressionMethod::Deflated)
        .large_file(meta.len() >= u32::MAX as u64);
    if meta.is_dir() {
        z.add_directory(format!("{entry}/"), opts).map_err(io::Error::other)?;
        for e in fs::read_dir(path)? {
            let e = e?;
            add_tree(z, &e.path(), &format!("{entry}/{}", e.file_name().to_string_lossy()))?;
        }
    } else {
        z.start_file(entry, opts).map_err(io::Error::other)?;
        io::copy(&mut File::open(path)?, z)?;
    }
    Ok(())
}

struct TempDir(PathBuf);

impl TempDir {
    fn new() -> io::Result<Self> {
        let d = std::env::temp_dir().join(format!("lidrop-{}", store::uuid()));
        fs::create_dir_all(&d)?;
        Ok(TempDir(d))
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

/// Android's MediaStore may add its own extension when the type and the name disagree, so unknowns stay generic.
pub fn mime_for(p: &Path) -> &'static str {
    let ext = p.extension().map(|e| e.to_string_lossy().to_ascii_lowercase()).unwrap_or_default();
    match ext.as_str() {
        "jpg" | "jpeg" => "image/jpeg",
        "png" => "image/png",
        "gif" => "image/gif",
        "webp" => "image/webp",
        "heic" => "image/heic",
        "heif" => "image/heif",
        "bmp" => "image/bmp",
        "svg" => "image/svg+xml",
        "mp4" | "m4v" => "video/mp4",
        "mov" => "video/quicktime",
        "mkv" => "video/x-matroska",
        "webm" => "video/webm",
        "avi" => "video/x-msvideo",
        "mp3" => "audio/mpeg",
        "m4a" => "audio/mp4",
        "wav" => "audio/wav",
        "flac" => "audio/flac",
        "ogg" => "audio/ogg",
        "pdf" => "application/pdf",
        "txt" => "text/plain",
        "csv" => "text/csv",
        "html" | "htm" => "text/html",
        "json" => "application/json",
        "xml" => "application/xml",
        "zip" => "application/zip",
        "7z" => "application/x-7z-compressed",
        "rar" => "application/vnd.rar",
        "gz" => "application/gzip",
        "tar" => "application/x-tar",
        "apk" => "application/vnd.android.package-archive",
        "doc" => "application/msword",
        "docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        "xls" => "application/vnd.ms-excel",
        "xlsx" => "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        "ppt" => "application/vnd.ms-powerpoint",
        "pptx" => "application/vnd.openxmlformats-officedocument.presentationml.presentation",
        _ => "application/octet-stream",
    }
}
