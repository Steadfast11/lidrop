//! `dumbpipe connect-tcp` as a library: a loopback TCP port whose connections continue over iroh to the Mac's
//! `dumbpipe listen-tcp`. Direct when the networks allow it, relayed when not, always end-to-end encrypted.
use std::ffi::{c_char, CStr};
use std::net::Ipv4Addr;
use std::str::FromStr;
use std::sync::Mutex;
use std::time::Duration;

use dumbpipe::{EndpointTicket, ALPN, HANDSHAKE};
use iroh::{endpoint::presets, Endpoint, EndpointAddr, SecretKey};
use tokio::io::{self, AsyncWriteExt};
use tokio::net::{TcpListener, TcpStream};
use tokio::runtime::Runtime;
use tokio::sync::watch;

const ONLINE_TIMEOUT: Duration = Duration::from_secs(5);

struct Running {
    ticket: String,
    port: u16,
    rt: Runtime,
}

static CUR: Mutex<Option<Running>> = Mutex::new(None);

async fn forward(tcp: TcpStream, ep: Endpoint, addr: EndpointAddr) -> Option<()> {
    let conn = ep.connect(addr, ALPN).await.ok()?;
    let (mut send, mut recv) = conn.open_bi().await.ok()?;
    send.write_all(&HANDSHAKE).await.ok()?; // the connecting side writes first, or the stream never opens
    let (mut tcp_r, mut tcp_w) = tcp.into_split();
    let up = async {
        let r = io::copy(&mut tcp_r, &mut send).await;
        let _ = send.finish();
        r
    };
    let down = async {
        let r = io::copy(&mut recv, &mut tcp_w).await;
        let _ = tcp_w.shutdown().await;
        r
    };
    // either side ending ends the phone's view of the link, so it reconnects instead of hanging half open
    tokio::select! { _ = up => {}, _ = down => {} }
    Some(())
}

async fn serve(listener: TcpListener, addr: EndpointAddr) {
    let (tx, rx) = watch::channel(None::<Endpoint>);
    tokio::spawn(async move {
        let ep = Endpoint::builder(presets::N0)
            .secret_key(SecretKey::generate())
            .alpns(vec![])
            .bind()
            .await;
        if let Ok(ep) = ep {
            let _ = tokio::time::timeout(ONLINE_TIMEOUT, ep.online()).await;
            let _ = tx.send(Some(ep));
            std::future::pending::<()>().await; // keeps the channel open for later connections
        }
    });
    while let Ok((tcp, _)) = listener.accept().await {
        let _ = tcp.set_nodelay(true);
        let addr = addr.clone();
        let mut rx = rx.clone();
        tokio::spawn(async move {
            let Ok(ep) = rx.wait_for(|e| e.is_some()).await.map(|e| e.clone().unwrap()) else { return };
            forward(tcp, ep, addr).await;
        });
    }
}

/// # Safety
/// `ticket` must be a valid NUL-terminated string.
#[no_mangle]
pub unsafe extern "C" fn lidrop_tunnel_start(ticket: *const c_char) -> u16 {
    let Ok(t) = CStr::from_ptr(ticket).to_str() else { return 0 };
    let mut cur = CUR.lock().unwrap();
    if let Some(r) = cur.as_ref().filter(|r| r.ticket == t) {
        return r.port;
    }
    if let Some(old) = cur.take() {
        old.rt.shutdown_background();
    }
    let Ok(parsed) = EndpointTicket::from_str(t) else { return 0 };
    let Ok(rt) = Runtime::new() else { return 0 };
    let Ok(listener) = rt.block_on(TcpListener::bind((Ipv4Addr::LOCALHOST, 0))) else { return 0 };
    let Ok(port) = listener.local_addr().map(|a| a.port()) else { return 0 };
    rt.spawn(serve(listener, parsed.endpoint_addr().clone()));
    *cur = Some(Running { ticket: t.to_string(), port, rt });
    port
}

#[no_mangle]
pub extern "C" fn lidrop_tunnel_stop() {
    if let Some(r) = CUR.lock().unwrap().take() {
        r.rt.shutdown_background();
    }
}
