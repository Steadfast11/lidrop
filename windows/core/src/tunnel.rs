//! Runs the bundled iroh tunnel: internet-reachable, end-to-end encrypted, forwards to the local TCP port.
//! A stable key keeps the ticket stable, so a phone paired once can always find this computer.
use crate::server::lock;
use crate::store;
use std::fs;
use std::io::{BufRead, BufReader, Read};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex};
use std::thread;
use std::time::Duration;

/// `dumbpipe` logs other words that begin with "endpoint"; a ticket is always far longer.
const MIN_TICKET: usize = 40;

/// The first ticket in a line of dumbpipe's output.
pub fn find_ticket(line: &str) -> Option<&str> {
    let mut rest = line;
    while let Some(at) = rest.find("endpoint") {
        let tail = &rest[at..];
        let end = tail.find(|c: char| !c.is_ascii_lowercase() && !c.is_ascii_digit()).unwrap_or(tail.len());
        if end >= MIN_TICKET {
            return Some(&tail[..end]);
        }
        rest = &tail[end.max(1)..];
    }
    None
}

pub fn secret(key_file: &Path) -> String {
    if let Ok(s) = fs::read_to_string(key_file) {
        if s.len() == 64 {
            return s;
        }
    }
    let s = store::random_hex(32);
    let _ = fs::write(key_file, &s);
    s
}

pub struct Tunnel {
    stopping: Arc<AtomicBool>,
    child: Arc<Mutex<Option<Child>>>,
}

impl Tunnel {
    /// `on_ticket` runs when the ticket first appears or changes; `on_spawn` sees every process started, so the
    /// shell can tie it to its own life. Restarted two seconds after it dies.
    pub fn start(
        binary: PathBuf,
        port: u16,
        key_file: &Path,
        on_ticket: impl Fn(String) + Send + Sync + 'static,
        on_spawn: impl Fn(&Child) + Send + 'static,
    ) -> Tunnel {
        let secret = secret(key_file);
        let stopping = Arc::new(AtomicBool::new(false));
        let child = Arc::new(Mutex::new(None::<Child>));
        let (stop, slot) = (stopping.clone(), child.clone());
        let on_ticket = Arc::new(on_ticket);
        thread::spawn(move || {
            let mut last = None::<String>;
            let last_seen = Arc::new(Mutex::new(None::<String>));
            while !stop.load(Ordering::Acquire) {
                let mut cmd = Command::new(&binary);
                cmd.args(["listen-tcp", "--host", &format!("127.0.0.1:{port}")])
                    .env("IROH_SECRET", &secret)
                    .stdin(Stdio::null())
                    .stdout(Stdio::piped())
                    .stderr(Stdio::piped());
                hide_console(&mut cmd);
                match cmd.spawn() {
                    Ok(mut c) => {
                        on_spawn(&c);
                        let readers = [
                            c.stdout.take().map(|o| Box::new(o) as Box<dyn Read + Send>),
                            c.stderr.take().map(|e| Box::new(e) as Box<dyn Read + Send>),
                        ];
                        let mut joins = Vec::new();
                        for r in readers.into_iter().flatten() {
                            let (t, seen) = (on_ticket.clone(), last_seen.clone());
                            joins.push(thread::spawn(move || {
                                for line in BufReader::new(r).lines().map_while(Result::ok) {
                                    if let Some(found) = find_ticket(&line) {
                                        let mut s = lock(&seen);
                                        if s.as_deref() != Some(found) {
                                            *s = Some(found.to_string());
                                            drop(s);
                                            t(found.to_string());
                                        }
                                    }
                                }
                            }));
                        }
                        *lock(&slot) = Some(c);
                        // both pipes end when the process does
                        joins.into_iter().for_each(|j| {
                            let _ = j.join();
                        });
                        if let Some(mut c) = lock(&slot).take() {
                            let _ = c.kill();
                            let _ = c.wait();
                        }
                    }
                    Err(e) => {
                        if last.as_deref() != Some(e.to_string().as_str()) {
                            eprintln!("tunnel: {e}");
                            last = Some(e.to_string());
                        }
                    }
                }
                thread::sleep(Duration::from_secs(2));
            }
        });
        Tunnel { stopping, child }
    }

    pub fn stop(&self) {
        self.stopping.store(true, Ordering::Release);
        if let Some(c) = lock(&self.child).as_mut() {
            let _ = c.kill();
        }
    }
}

impl Drop for Tunnel {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(windows)]
fn hide_console(cmd: &mut Command) {
    use std::os::windows::process::CommandExt;
    const CREATE_NO_WINDOW: u32 = 0x0800_0000;
    cmd.creation_flags(CREATE_NO_WINDOW); // it is a console program; no black box may flash
}

#[cfg(not(windows))]
fn hide_console(_: &mut Command) {}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn finds_the_ticket_and_only_the_ticket() {
        let t = format!("endpoint{}", "ab2".repeat(40));
        assert_eq!(find_ticket(&format!("  dumbpipe connect-tcp {t}")), Some(t.as_str()));
        assert_eq!(find_ticket("bound endpoint on 0.0.0.0, endpoints ready"), None);
        assert_eq!(find_ticket(&format!("endpoint id x then {t} tail")), Some(t.as_str()));
    }

    #[test]
    fn the_key_stays_the_same() {
        let d = tempfile::tempdir().unwrap();
        let k = d.path().join("tunnel.key");
        let a = secret(&k);
        assert_eq!(a.len(), 64);
        assert_eq!(a, secret(&k));
    }
}
