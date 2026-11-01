//! `_lidrop._tcp` over mDNS, with the computer's name, so the phones find it without an address.
use mdns_sd::{IfKind, ServiceDaemon, ServiceInfo};
use std::net::{IpAddr, UdpSocket};

const SERVICE: &str = "_lidrop._tcp.local.";

/// Advertising lasts as long as this is kept.
pub struct Advert(#[allow(dead_code)] ServiceDaemon);

pub fn advertise(name: &str, port: u16) -> Result<Advert, mdns_sd::Error> {
    let d = ServiceDaemon::new()?;
    // Android's NsdManager hands the app one address; an IPv6 link-local one is of no use to a plain socket
    d.disable_interface(IfKind::IPv6)?;
    let host: String = name.chars().map(|c| if c.is_ascii_alphanumeric() { c } else { '-' }).collect();
    let info = ServiceInfo::new(SERVICE, name, &format!("{host}-lidrop.local."), "", port, None::<std::collections::HashMap<String, String>>)?
        .enable_addr_auto();
    d.register(info)?;
    Ok(Advert(d))
}

/// The address other devices would reach this computer on, for the tray. Sends nothing: connecting a UDP socket
/// only picks the route.
pub fn local_ip() -> Option<IpAddr> {
    let s = UdpSocket::bind(("0.0.0.0", 0)).ok()?;
    s.connect(("8.8.8.8", 53)).ok()?;
    s.local_addr().ok().map(|a| a.ip())
}
