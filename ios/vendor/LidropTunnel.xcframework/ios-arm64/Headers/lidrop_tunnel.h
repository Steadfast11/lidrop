#include <stdint.h>

/// Starts the tunnel to the Mac in `ticket` (same ticket as the same call before: keeps it running).
/// Returns the loopback TCP port speaking to the Mac, 0 if the ticket is invalid.
uint16_t lidrop_tunnel_start(const char *ticket);

/// Stops the tunnel: iOS kills its sockets while the app is suspended, so it does not outlive the foreground.
void lidrop_tunnel_stop(void);
