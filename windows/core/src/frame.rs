//! PROTOCOL.md framing: `u32 BE length N` · `u8 type` · `N-1 bytes payload`.
use std::io::{self, Read};

pub const CONTROL: u8 = 1;
pub const CHUNK: u8 = 2;
pub const BLOCK: u8 = 3;
pub const CHUNK_SIZE: usize = 256 * 1024;

/// A `drag_start` with its thumbnail is the largest legitimate frame; anything far past that is not a phone.
pub const MAX_FRAME: usize = 16 << 20;

/// Reads one frame into `buf` and returns its type, or `None` on a clean end of stream.
pub fn read_frame(r: &mut impl Read, buf: &mut Vec<u8>) -> io::Result<Option<u8>> {
    let mut head = [0u8; 4];
    match r.read_exact(&mut head) {
        Err(e) if e.kind() == io::ErrorKind::UnexpectedEof => return Ok(None),
        other => other?,
    }
    let n = u32::from_be_bytes(head) as usize;
    if n == 0 || n > MAX_FRAME {
        return Err(io::Error::new(io::ErrorKind::InvalidData, format!("bad frame length {n}")));
    }
    let mut kind = [0u8; 1];
    r.read_exact(&mut kind)?;
    buf.resize(n - 1, 0);
    r.read_exact(buf)?;
    Ok(Some(kind[0]))
}

pub fn encode(kind: u8, payload: &[u8]) -> Vec<u8> {
    let mut f = Vec::with_capacity(payload.len() + 5);
    f.extend_from_slice(&(payload.len() as u32 + 1).to_be_bytes());
    f.push(kind);
    f.extend_from_slice(payload);
    f
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_and_clean_end() {
        let mut wire = encode(CONTROL, b"{}");
        wire.extend(encode(CHUNK, &[7; 300]));
        let mut r = &wire[..];
        let mut b = Vec::new();
        assert_eq!(read_frame(&mut r, &mut b).unwrap(), Some(CONTROL));
        assert_eq!(b, b"{}");
        assert_eq!(read_frame(&mut r, &mut b).unwrap(), Some(CHUNK));
        assert_eq!(b.len(), 300);
        assert_eq!(read_frame(&mut r, &mut b).unwrap(), None);
    }

    #[test]
    fn refuses_zero_and_absurd_lengths() {
        let mut b = Vec::new();
        assert!(read_frame(&mut &0u32.to_be_bytes()[..], &mut b).is_err());
        assert!(read_frame(&mut &u32::MAX.to_be_bytes()[..], &mut b).is_err());
    }
}
