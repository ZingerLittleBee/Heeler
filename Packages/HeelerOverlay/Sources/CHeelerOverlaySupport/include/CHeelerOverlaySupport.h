#ifndef C_HEELER_OVERLAY_SUPPORT_H
#define C_HEELER_OVERLAY_SUPPORT_H

#include <stdint.h>

/*
 * A byte pump between one end of an AF_UNIX socketpair and a stream on an
 * in-process network stack whose descriptors are not OS descriptors (libzt's
 * lwIP sockets). The caller gets the other socketpair end as an ordinary
 * descriptor.
 *
 * One dedicated thread owns both sides for the stream's whole life, because
 * lwIP is built without full-duplex netconns: a socket must never be read
 * and written from two threads at once. The thread waits with short timed
 * polls on each side in turn, so it never spins, and preserves half-close in
 * both directions: EOF from one side becomes a write shutdown on the other
 * once the buffered bytes are delivered.
 */
typedef struct heeler_overlay_pump heeler_overlay_pump;

/* Result codes shared by the functions below. */
enum {
    HEELER_OVERLAY_OK = 0,
    HEELER_OVERLAY_ERR_ARGUMENT = -1,
    HEELER_OVERLAY_ERR_SOCKET = -2,
    HEELER_OVERLAY_ERR_TIMEOUT = -3,
    HEELER_OVERLAY_ERR_REFUSED = -4,
    HEELER_OVERLAY_ERR_RESOURCES = -5,
    HEELER_OVERLAY_ERR_CANCELLED = -6,
    /* The node has no address of the destination's family on the network. */
    HEELER_OVERLAY_ERR_NO_SOURCE = -7,
    /* The network has no route to the destination (its subnet, or one of
     * its managed routes through a gateway on that subnet). */
    HEELER_OVERLAY_ERR_NO_ROUTE = -8,
};

/* A thread-safe cancellation flag for blocking native calls. */
typedef struct heeler_overlay_cancel heeler_overlay_cancel;

heeler_overlay_cancel *heeler_overlay_cancel_create(void);
void heeler_overlay_cancel_set(heeler_overlay_cancel *cancel);
int heeler_overlay_cancel_is_set(const heeler_overlay_cancel *cancel);
void heeler_overlay_cancel_destroy(heeler_overlay_cancel *cancel);

/*
 * Connects a libzt TCP socket to `ip` (an IPv4 or IPv6 literal) and `port`.
 * Unless `net_id` is 0, the socket is first bound to the node's address of
 * the same family on that joined network and to that network's interface,
 * so the connection goes through that network only, even when another
 * joined network assigned the node the same address:
 * HEELER_OVERLAY_ERR_NO_SOURCE when the network has no such address (or
 * interface), HEELER_OVERLAY_ERR_NO_ROUTE at once when it cannot reach an
 * IPv4 destination (neither on its subnet nor behind one of its managed
 * gateway routes) instead of waiting for the timeout.
 * Waits at most `timeout_ms`, and stops early once `cancel` is set (checked
 * between short polls; may be NULL). On success stores the connected,
 * non-blocking lwIP descriptor in `*zts_fd_out`.
 */
int heeler_zt_connect(
    const char *ip,
    uint16_t port,
    uint64_t net_id,
    int timeout_ms,
    const heeler_overlay_cancel *cancel,
    int *zts_fd_out);

/*
 * Starts a pump for a connected libzt descriptor, taking ownership of it
 * (it is closed on failure too). Returns the caller's socketpair end, or a
 * negative result code. `*pump_out` must be released exactly once.
 */
int heeler_zt_pump_start(int zts_fd, heeler_overlay_pump **pump_out);

/*
 * Same pump over an ordinary connected OS socket instead of libzt. Exists so
 * the pump's buffering, EOF, and half-close behavior can be tested without a
 * running ZeroTier node. Takes ownership of `remote_fd`.
 */
int heeler_posix_pump_start(int remote_fd, heeler_overlay_pump **pump_out);

/*
 * Test fault injection: like heeler_posix_pump_start, but for the first
 * `stall_ms` every send to `remote_fd` reports would-block although the
 * socket is writable — the pattern a congested lwIP socket produces.
 */
int heeler_posix_pump_start_stalling_sends(
    int remote_fd,
    int stall_ms,
    heeler_overlay_pump **pump_out);

/*
 * Asks the pump to stop and drops the caller's reference. Never blocks. The
 * pump thread closes both its descriptors when it exits, which happens on
 * its own once both directions are finished, or within one poll interval
 * after release.
 */
void heeler_overlay_pump_release(heeler_overlay_pump *pump);

/* Number of pump threads that have not exited yet (diagnostics and tests). */
int heeler_overlay_pump_live_count(void);

#endif
