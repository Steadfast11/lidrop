//! A file arriving from the phone, chunk by chunk or as numbered video blocks.
use crate::frame::CHUNK_SIZE;
use crate::store::{self, claim_path};
use std::fs::{self, File};
use std::io::{self, Seek, SeekFrom, Write};
use std::path::{Path, PathBuf};

/// A hidden file beside the final one, so the move at the end cannot cross drives.
pub struct Partial {
    file: Option<File>,
    path: PathBuf,
}

impl Partial {
    pub fn create(dir: &Path) -> io::Result<Self> {
        fs::create_dir_all(dir)?;
        let path = dir.join(format!(".partial-{}", store::uuid()));
        Ok(Partial { file: Some(File::create(&path)?), path })
    }

    pub fn write(&mut self, data: &[u8]) -> io::Result<()> {
        self.file.as_mut().expect("open until saved").write_all(data)
    }

    /// Closes the file and moves it to a free name in `dir` built from `name`.
    pub fn save(mut self, dir: &Path, name: &str) -> io::Result<PathBuf> {
        drop(self.file.take()); // Windows cannot move an open file
        let dest = claim_path(dir, name)?;
        match fs::rename(&self.path, &dest) {
            Ok(()) => Ok(dest),
            Err(e) => {
                let _ = fs::remove_file(&dest);
                Err(e)
            }
        }
    }
}

impl Drop for Partial {
    fn drop(&mut self) {
        drop(self.file.take());
        let _ = fs::remove_file(&self.path);
    }
}

/// A video sent as numbered blocks, in any order. The size is known up front, so each block has its place.
pub struct StreamFile {
    out: Partial,
    have: Vec<bool>,
    left: usize,
    shown: i64,
}

impl StreamFile {
    pub fn create(dir: &Path, size: u64) -> io::Result<Self> {
        let out = Partial::create(dir)?;
        out.file.as_ref().expect("just opened").set_len(size)?;
        let n = size.div_ceil(CHUNK_SIZE as u64) as usize;
        Ok(StreamFile { out, have: vec![false; n], left: n, shown: -1 })
    }

    /// One frame of type 3: u32 BE block index, then the bytes. Returns the new percentage when it changes.
    pub fn write(&mut self, frame: &[u8]) -> io::Result<Option<u32>> {
        if frame.len() <= 4 || frame.len() > CHUNK_SIZE + 4 {
            return Ok(None);
        }
        let b = u32::from_be_bytes([frame[0], frame[1], frame[2], frame[3]]) as usize;
        if b >= self.have.len() {
            return Ok(None);
        }
        let f = self.out.file.as_mut().expect("open until saved");
        f.seek(SeekFrom::Start(b as u64 * CHUNK_SIZE as u64))?;
        f.write_all(&frame[4..])?;
        if !self.have[b] {
            self.have[b] = true;
            self.left -= 1;
        }
        let pct = 100 - (self.left * 100 / self.have.len()) as i64;
        if pct == self.shown {
            return Ok(None);
        }
        self.shown = pct;
        Ok(Some(pct as u32))
    }

    pub fn complete(&self) -> bool {
        self.left == 0
    }

    pub fn save(self, dir: &Path, name: &str) -> io::Result<PathBuf> {
        self.out.save(dir, name)
    }
}
