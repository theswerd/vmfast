// slirpnet — a thin C shim over libslirp for vmfast-linux.
//
// libslirp is a userspace TCP/IP NAT (the same stack behind QEMU's
// "-net user"). It needs no root, no kernel extension, no daemon — the
// whole stack lives in-process and stands up in well under a
// millisecond, which is why it fits vmfast's "VM ready in 1 ms" budget
// where vmnet's daemon/DHCP handshake would not.
//
// This shim owns every libslirp call (libslirp is not thread-safe, so
// all access is serialized behind one mutex) and runs slirp's socket
// poll loop on its own thread. The VMM (Swift) only deals in raw
// Ethernet frames:
//   guest TX → slnet_tx()        (Swift calls us)
//   host  RX → deliver callback  (we call Swift)
#ifndef SLIRPNET_H
#define SLIRPNET_H

#include <stddef.h>
#include <stdint.h>

// Invoked when slirp has an Ethernet frame to hand to the guest. Called
// from slirp's poll thread (and, for synchronous replies like ARP, from
// whichever thread called slnet_tx) with libslirp's lock held — the
// implementation must copy the bytes out and return promptly without
// calling back into slirpnet.
typedef void (*slnet_deliver_fn)(const uint8_t *frame, size_t len, void *ctx);

// Create the slirp stack (10.0.2.0/24, gateway/DNS 10.0.2.2/.3, guest
// 10.0.2.15) and spawn its poll thread. Returns an opaque handle or
// NULL on failure.
void *slnet_start(slnet_deliver_fn deliver, void *ctx);

// Forward host 127.0.0.1:host_port → guest 10.0.2.15:guest_port (TCP).
// Returns 0 on success. This is what lets the host connect to a
// listener (e.g. netcat) running inside the guest.
int slnet_hostfwd(void *handle, int host_port, int guest_port);

// Hand a guest-transmitted Ethernet frame to slirp. Thread-safe.
void slnet_tx(void *handle, const uint8_t *frame, size_t len);

#endif
