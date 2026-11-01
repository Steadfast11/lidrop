//! lidrop's Windows receiver, minus Windows: the wire protocol, files, trust, the tunnel and the drawing.
//! Everything here builds and runs on any OS so it can be tested with a fake phone; `app` adds the Win32 shell.
pub mod discovery;
pub mod frame;
pub mod receive;
pub mod render;
pub mod send;
pub mod server;
pub mod stage;
pub mod store;
pub mod thumb;
pub mod tunnel;
pub mod zone;

pub use render::Image;
pub use server::{Config, Cue, Edge, Host, Note, Server};
