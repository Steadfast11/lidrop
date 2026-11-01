import LidropTunnel

/**
 * The iroh tunnel to the Mac: works across networks, direct when the networks allow it, relayed when not, always
 * end-to-end encrypted. The app talks plain framing to a loopback port. iOS cannot run the dumbpipe binary the Android
 * app starts, so ios/tunnel builds the same thing as a library; each process gets its own port.
 */
enum Tunnel {
    /// The loopback port to dial, nil for an invalid ticket.
    static func up(_ ticket: String) -> UInt16? {
        let p = lidrop_tunnel_start(ticket)
        return p == 0 ? nil : p
    }

    static func down() { lidrop_tunnel_stop() }
}
