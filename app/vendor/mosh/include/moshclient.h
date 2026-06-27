// A plain-C interface over mosh's C++ client transport, so Swift can drive a
// mosh session without C++ interop. Implemented in moshclient.cpp.
#ifndef BSNS_MOSHCLIENT_H
#define BSNS_MOSHCLIENT_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct MoshClient MoshClient;

/// Open a mosh client to ip:port using the base64 session key from
/// `mosh-server`'s "MOSH CONNECT" line. Returns a handle (check last_error).
MoshClient* mosh_client_create(const char* ip, const char* port, const char* key, int cols, int rows);
void mosh_client_free(MoshClient* c);

/// The newest UDP socket to poll for readability. Kept for simpler bridges.
int mosh_client_fd(MoshClient* c);
/// Copy the current UDP sockets into `out` and return the number copied. Mosh
/// keeps old sockets briefly after a port hop, so clients that support roaming
/// should poll every fd this returns.
int mosh_client_fds(MoshClient* c, int* out, int capacity);
/// Suggested poll timeout (ms) before the next tick is due.
int mosh_client_wait_ms(MoshClient* c);

/// Refresh mosh's frozen monotonic clock. Mosh reads time from a cached value
/// that only updates here; the event loop MUST call this once at the top of
/// every iteration or all send/ack timers stall after the first packet (so
/// input is never transmitted). Mirrors stmclient.cc's per-iteration freeze.
void mosh_client_freeze_time(void);

/// Process an incoming datagram (call when the socket is readable). Returns 1 if a
/// real peer packet was received and decrypted, 0 if nothing valid was read (EAGAIN,
/// a stray/ICMP wake on a dead post-hop socket, a failed decrypt, or a duplicate).
int mosh_client_recv(MoshClient* c);
/// Send any pending local state / keepalive.
void mosh_client_tick(MoshClient* c);

/// Force the connection onto a fresh local socket (mosh roaming), preserving the
/// crypto session/sequence numbers. Call on resume from background, where iOS has
/// torn down the suspended UDP socket — recovers immediately instead of waiting
/// for mosh's ~10s auto-hop.
void mosh_client_hop(MoshClient* c);

/// Re-enable mosh's active resend window after an app suspend. Upstream mosh
/// intentionally stops retrying unchanged local state after ~10s without remote
/// contact; on iOS resume that can leave typed input sent once but never
/// retransmitted. This only affects sender retry timing, not remote liveness.
void mosh_client_prime_active_retry(MoshClient* c);

/// Drop the diff baseline so the next mosh_client_drain_ansi emits a FULL repaint
/// (clear + full framebuffer redraw) rather than a delta. Call on resume to fix a
/// desynced display (wrong row count / gap) after the app was backgrounded.
void mosh_client_force_repaint(MoshClient* c);

/// Queue local input bytes / a terminal resize to send to the server.
void mosh_client_push(MoshClient* c, const char* bytes, int len);
void mosh_client_resize(MoshClient* c, int cols, int rows);

/// Report the ACTUAL dimensions of the latest synced remote framebuffer (what
/// mosh is really drawing), as opposed to the size we last asked for. On resume
/// a mismatch here is the smoking gun for the display desync. Writes 0x0 if no
/// remote state has arrived yet.
void mosh_client_fb_dims(MoshClient* c, int* cols, int* rows);

/// If the remote terminal state advanced, returns a malloc'd ANSI frame (caller
/// frees) to feed the terminal; otherwise NULL.
char* mosh_client_drain_ansi(MoshClient* c);

/// Monotonic remote state number, useful for diagnostics around "input sent but
/// no visible output" resume failures.
uint64_t mosh_client_state_num(MoshClient* c);

const char* mosh_client_last_error(MoshClient* c);

#ifdef __cplusplus
}
#endif
#endif
